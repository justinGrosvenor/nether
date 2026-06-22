//! virtio-pci modern transport (virtio 1.x). Presents a virtio device as a PCI
//! function whose BAR0 holds the common/notify/isr/device-config structures plus
//! the MSI-X table. The driver drives feature negotiation and queue programming
//! through the common config; a notify-region write kicks a queue, processed by
//! the backend via virtq.zig. Completions interrupt the guest via MSI-X
//! (signalMsi) since there is no userspace IOAPIC; the ISR byte tracks legacy.

const std = @import("std");
const virtq = @import("virtq.zig");
const io = @import("io.zig");
const pci = @import("pci.zig");
const trace = @import("trace.zig");
const Lock = @import("lock.zig").Lock;

pub const max_queues = 8;
pub const num_vectors = 4; // MSI-X table entries
const no_vector: u16 = 0xffff;

// device_status bits
pub const ACKNOWLEDGE = 1;
pub const DRIVER = 2;
pub const DRIVER_OK = 4;
pub const FEATURES_OK = 8;

pub const VIRTIO_F_VERSION_1: u64 = 1 << 32;

// BAR0 region offsets and size (size must be a power of two).
pub const bar_size = 0x8000;
const common_off = 0x0000;
const isr_off = 0x1000;
const notify_off = 0x2000;
const device_off = 0x3000;
const msix_off = 0x4000; // MSI-X table
const pba_off = 0x5000; // MSI-X pending bit array

const cap_msix = 0x84; // MSI-X capability offset in config space

const MsixEntry = struct { addr: u64 = 0, data: u32 = 0, ctrl: u32 = 1 }; // ctrl bit0 = masked

pub const Backend = struct {
    ptr: *anyopaque,
    device_id: u16,
    num_queues: u16,
    device_features: u64,
    notify: *const fn (ptr: *anyopaque, dev: *Device, q: u16) void,
    config_read: *const fn (ptr: *anyopaque, off: u16, size: u8) u32,
};

pub const Device = struct {
    backend: Backend,
    mem: virtq.GuestMem,
    features: u64,

    config: [256]u8 = undefined,
    bar0: u32 = 0,
    bar1: u32 = 0,
    probe_lo: bool = false,
    probe_hi: bool = false,

    device_feature_select: u32 = 0,
    driver_feature_select: u32 = 0,
    driver_features: u64 = 0,
    status: u8 = 0,
    queue_select: u16 = 0,
    isr: u8 = 0,

    queues: [max_queues]virtq.Virtqueue = undefined,
    qenable: [max_queues]bool = [_]bool{false} ** max_queues,

    msix_enabled: bool = false,
    config_vector: u16 = no_vector,
    queue_vector: [max_queues]u16 = [_]u16{no_vector} ** max_queues,
    msix_table: [num_vectors]MsixEntry = [_]MsixEntry{.{}} ** num_vectors,
    /// Guards the interrupt/transport state (isr, msix_enabled, queue_vector,
    /// msix_table) shared between `interruptQueue` - called from host I/O threads
    /// (virtio-net/vsock RX) - and the guest's MMIO config/MSI-X/ISR writes on the
    /// vCPU thread. Held only across these field accesses, never across a queue
    /// drain or a syscall. MUST stay distinct from `dev_lock`: the notify path holds
    /// `dev_lock` and then calls `interruptQueue`, so sharing one lock would
    /// self-deadlock. Lock order is always dev_lock -> irq_lock.
    irq_lock: Lock = .{},
    /// Serializes vCPU<->vCPU access to this device's MMIO (queues, config, status).
    /// The bus no longer holds its lock across virtio handlers (the PCI BAR window
    /// is self_locked), so concurrent vCPUs to the SAME device serialize here while
    /// different devices run in parallel. Taken at the top of barRead/barWrite. Host
    /// I/O threads don't take it (they reach interrupt state via irq_lock and queue
    /// state via the backend's own lock).
    dev_lock: Lock = .{},

    // Legacy IRQ callback (unused once MSI-X is on) and the MSI sink.
    irq_ptr: ?*anyopaque = null,
    irq_fn: ?*const fn (ptr: *anyopaque) void = null,
    msi_ptr: ?*anyopaque = null,
    msi_fn: ?*const fn (ptr: *anyopaque, addr: u64, data: u32) void = null,
    // Legacy PCI INTx as a level line (aarch64, where there is no MSI domain in
    // the DTB so the guest virtio-pci driver falls back to INTx). Raised when the
    // ISR is set, lowered when the guest reads (and thereby clears) the ISR.
    intx_ptr: ?*anyopaque = null,
    intx_fn: ?*const fn (ptr: *anyopaque, level: bool) void = null,

    pub fn init(backend: Backend, mem: virtq.GuestMem) Device {
        var d = Device{
            .backend = backend,
            .mem = mem,
            .features = VIRTIO_F_VERSION_1 | backend.device_features,
        };
        d.resetQueues();
        d.buildConfig();
        return d;
    }

    fn resetQueues(self: *Device) void {
        for (&self.queues) |*q| q.* = .{ .size = 256, .desc = 0, .avail = 0, .used = 0 };
        self.qenable = [_]bool{false} ** max_queues;
    }

    fn buildConfig(self: *Device) void {
        @memset(&self.config, 0);
        const c = &self.config;
        std.mem.writeInt(u16, c[0..2], 0x1af4, .little);
        std.mem.writeInt(u16, c[2..4], 0x1040 + self.backend.device_id, .little);
        std.mem.writeInt(u16, c[6..8], 0x0010, .little); // status: cap list
        c[8] = 0x01; // revision (modern)
        // PCI class code (bytes 0x09 prog-if, 0x0a subclass, 0x0b base class).
        // This MUST be non-zero: the Linux resource assigner skips any device
        // whose class>>8 is PCI_CLASS_NOT_DEFINED (0x0000) in __dev_sort_resources,
        // leaving its BARs unassigned ("not claimed; can't enable device"). We
        // mirror QEMU virtio-pci's per-type classes; default is PCI_CLASS_OTHERS.
        const class_dev: u16 = switch (self.backend.device_id) {
            1 => 0x0200, // net
            2 => 0x0100, // block (mass storage)
            3 => 0x0780, // console (simple comms)
            else => 0x00ff, // rng and others: PCI_CLASS_OTHERS
        };
        std.mem.writeInt(u16, c[0x0a..0x0c], class_dev, .little); // base/subclass
        c[0x0e] = 0x00; // header type 0
        // Interrupt Pin = INTA. On a DT boot with no MSI domain the guest routes
        // this through the pcie interrupt-map to a GIC SPI and uses INTx; without
        // a non-zero pin the PCI core assigns no IRQ and find_vqs has none to use.
        c[0x3d] = 0x01;
        std.mem.writeInt(u16, c[0x2c..0x2e], 0x1af4, .little);
        std.mem.writeInt(u16, c[0x2e..0x30], self.backend.device_id, .little);
        c[0x34] = 0x40; // cap pointer

        writeVirtioCap(c, 0x40, 0x50, 16, 1, common_off, 0x1000);
        writeVirtioCap(c, 0x50, 0x64, 20, 2, notify_off, 0x1000);
        std.mem.writeInt(u32, c[0x50 + 16 ..][0..4], 0, .little); // notify_off_multiplier
        writeVirtioCap(c, 0x64, 0x74, 16, 3, isr_off, 0x1000);
        writeVirtioCap(c, 0x74, cap_msix, 16, 4, device_off, 0x1000);

        // MSI-X capability.
        c[cap_msix + 0] = 0x11; // PCI_CAP_ID_MSIX
        c[cap_msix + 1] = 0x00; // next
        std.mem.writeInt(u16, c[cap_msix + 2 ..][0..2], num_vectors - 1, .little); // table size - 1
        std.mem.writeInt(u32, c[cap_msix + 4 ..][0..4], msix_off, .little); // table: BAR0, offset
        std.mem.writeInt(u32, c[cap_msix + 8 ..][0..4], pba_off, .little); // PBA: BAR0, offset
    }

    fn qsel(self: *Device) usize {
        return @min(self.queue_select, max_queues - 1);
    }

    /// Largest queue the device advertises (also the reset default). A driver may
    /// negotiate any power-of-2 down from here.
    pub const QUEUE_SIZE_MAX: u16 = 256;

    /// virtio requires a queue size that is a nonzero power of two within the
    /// advertised max. Anything else (notably 0) must never reach the virtq code,
    /// where it would divide-by-zero on the ring-index modulo.
    fn validQueueSize(sz: u16) bool {
        return sz != 0 and sz <= QUEUE_SIZE_MAX and (sz & (sz - 1)) == 0;
    }

    pub fn queue(self: *Device, i: u16) *virtq.Virtqueue {
        return &self.queues[@min(i, max_queues - 1)];
    }
    pub fn memory(self: *Device) virtq.GuestMem {
        return self.mem;
    }
    pub fn assignBar(self: *Device, base: u64) void {
        self.bar0 = @as(u32, @truncate(base)) & 0xFFFFFFF0;
        self.bar1 = @truncate(base >> 32);
    }
    pub fn barBase(self: *Device) u64 {
        return (@as(u64, self.bar1) << 32) | (self.bar0 & 0xFFFFFFF0);
    }

    /// Pointer-free snapshot of a Device's mutable transport state. The live
    /// Device's backend/mem/IRQ pointers are not portable across a process, so a
    /// snapshot carries only the data fields; the restore side rewires the
    /// pointers by re-initializing the Device and then importing this state.
    pub const DeviceState = struct {
        features: u64,
        driver_features: u64,
        device_feature_select: u32,
        driver_feature_select: u32,
        status: u8,
        queue_select: u16,
        isr: u8,
        bar0: u32,
        bar1: u32,
        config: [256]u8,
        queues: [max_queues]virtq.Virtqueue,
        qenable: [max_queues]bool,
        msix_enabled: bool,
        config_vector: u16,
        queue_vector: [max_queues]u16,
        msix_table: [num_vectors]MsixEntry,
    };

    pub fn exportState(self: *const Device) DeviceState {
        return .{
            .features = self.features,
            .driver_features = self.driver_features,
            .device_feature_select = self.device_feature_select,
            .driver_feature_select = self.driver_feature_select,
            .status = self.status,
            .queue_select = self.queue_select,
            .isr = self.isr,
            .bar0 = self.bar0,
            .bar1 = self.bar1,
            .config = self.config,
            .queues = self.queues,
            .qenable = self.qenable,
            .msix_enabled = self.msix_enabled,
            .config_vector = self.config_vector,
            .queue_vector = self.queue_vector,
            .msix_table = self.msix_table,
        };
    }

    pub fn importState(self: *Device, s: *const DeviceState) void {
        self.features = s.features;
        self.driver_features = s.driver_features;
        self.device_feature_select = s.device_feature_select;
        self.driver_feature_select = s.driver_feature_select;
        self.status = s.status;
        self.queue_select = s.queue_select;
        self.isr = s.isr;
        self.bar0 = s.bar0;
        self.bar1 = s.bar1;
        self.config = s.config;
        self.queues = s.queues;
        self.qenable = s.qenable;
        self.msix_enabled = s.msix_enabled;
        self.config_vector = s.config_vector;
        self.queue_vector = s.queue_vector;
        self.msix_table = s.msix_table;
    }

    /// Raise the completion interrupt for queue `q`: MSI-X if enabled, else the
    /// legacy ISR/IRQ. Backends call this after publishing to the used ring.
    pub fn interruptQueue(self: *Device, q: u16) void {
        self.irq_lock.lock();
        defer self.irq_lock.unlock();
        self.isr |= 1;
        if (self.msix_enabled) {
            const vec = if (q < max_queues) self.queue_vector[q] else no_vector;
            if (vec != no_vector and vec < num_vectors and self.msix_table[vec].ctrl & 1 == 0) {
                const e = self.msix_table[vec];
                trace.log("msi q={d} vec={d} addr=0x{x} data=0x{x}", .{ q, vec, e.addr, e.data });
                if (self.msi_fn) |f| f(self.msi_ptr.?, e.addr, e.data);
            }
        } else {
            if (self.irq_fn) |f| f(self.irq_ptr.?);
            if (self.intx_fn) |f| f(self.intx_ptr.?, true); // INTx level high
        }
    }

    // --- PCI config space ---------------------------------------------------

    pub fn function(self: *Device, dev_num: u5, func_num: u3) pci.Function {
        return .{ .ptr = self, .dev = dev_num, .func = func_num, .read = cfgReadThunk, .write = cfgWriteThunk };
    }
    fn cfgReadThunk(ptr: *anyopaque, reg: u16, size: u8) u32 {
        return cast(ptr).cfgRead(reg, size);
    }
    fn cfgWriteThunk(ptr: *anyopaque, reg: u16, size: u8, value: u32) void {
        cast(ptr).cfgWrite(reg, size, value);
    }

    pub fn cfgRead(self: *Device, reg: u16, size: u8) u32 {
        // BAR0: 64-bit (bit 2), prefetchable (bit 3) -> low nibble 0x0C. The
        // aarch64 DTB provides a 64-bit window for it (and a separate 32-bit
        // non-prefetchable window the host bridge also requires); x86 is unchanged.
        if (size == 4 and reg == 0x10) return if (self.probe_lo) (~@as(u32, bar_size - 1)) | 0x0C else (self.bar0 & 0xFFFFFFF0) | 0x0C;
        if (size == 4 and reg == 0x14) return if (self.probe_hi) 0xFFFFFFFF else self.bar1;
        var v: u32 = 0;
        var i: usize = 0;
        while (i < size and reg + i < self.config.len) : (i += 1) v |= @as(u32, self.config[reg + i]) << @intCast(i * 8);
        return v;
    }

    pub fn cfgWrite(self: *Device, reg: u16, size: u8, value: u32) void {
        if (size == 4 and reg == 0x10) {
            if (value == 0xFFFFFFFF) self.probe_lo = true else {
                self.bar0 = value & 0xFFFFFFF0;
                self.probe_lo = false;
                trace.log("bar0=0x{x}", .{self.bar0});
            }
        } else if (size == 4 and reg == 0x14) {
            if (value == 0xFFFFFFFF) self.probe_hi = true else {
                self.bar1 = value;
                self.probe_hi = false;
            }
        } else if (reg == cap_msix + 2) {
            // MSI-X message control: bit 15 enable, bit 14 function mask.
            const mc: u16 = @truncate(value);
            std.mem.writeInt(u16, self.config[cap_msix + 2 ..][0..2], mc, .little);
            self.irq_lock.lock();
            self.msix_enabled = mc & 0x8000 != 0;
            self.irq_lock.unlock();
            trace.log("msix enable={}", .{self.msix_enabled});
        }
    }

    // --- BAR MMIO -----------------------------------------------------------

    pub fn mmio(self: *Device) io.MmioDevice {
        return .{ .ptr = self, .base = self.barBase(), .len = bar_size, .read_fn = mmioReadThunk, .write_fn = mmioWriteThunk };
    }
    fn mmioReadThunk(ptr: *anyopaque, offset: u64, data: []u8) void {
        putLE(data, cast(ptr).barRead(offset, @intCast(data.len)));
    }
    fn mmioWriteThunk(ptr: *anyopaque, offset: u64, data: []const u8) void {
        cast(ptr).barWrite(offset, @intCast(data.len), getLE(data));
    }

    pub fn barRead(self: *Device, off: u64, size: u8) u32 {
        self.dev_lock.lock();
        defer self.dev_lock.unlock();
        if (off < isr_off) return self.commonRead(@intCast(off));
        if (off < notify_off) {
            self.irq_lock.lock();
            defer self.irq_lock.unlock();
            const v = self.isr;
            self.isr = 0;
            if (self.intx_fn) |f| f(self.intx_ptr.?, false); // INTx level low after ISR read
            return v;
        }
        if (off < device_off) return 0; // notify region
        if (off < msix_off) return self.backend.config_read(self.backend.ptr, @intCast(off - device_off), size);
        if (off < pba_off) return self.msixRead(@intCast(off - msix_off));
        return 0; // PBA: nothing pending
    }

    pub fn barWrite(self: *Device, off: u64, size: u8, value: u32) void {
        _ = size;
        self.dev_lock.lock();
        defer self.dev_lock.unlock();
        if (off < isr_off) {
            self.commonWrite(@intCast(off), value);
        } else if (off >= notify_off and off < device_off) {
            const q: u16 = @truncate(value);
            trace.log("notify q={d}", .{q});
            if (q < max_queues and self.qenable[q]) self.backend.notify(self.backend.ptr, self, q);
        } else if (off >= msix_off and off < pba_off) {
            self.msixWrite(@intCast(off - msix_off), value);
        }
    }

    fn msixRead(self: *Device, off: u32) u32 {
        const entry = off / 16;
        if (entry >= num_vectors) return 0;
        const e = self.msix_table[entry];
        return switch (off % 16) {
            0 => @truncate(e.addr),
            4 => @truncate(e.addr >> 32),
            8 => e.data,
            12 => e.ctrl,
            else => 0,
        };
    }

    fn msixWrite(self: *Device, off: u32, value: u32) void {
        const entry = off / 16;
        if (entry >= num_vectors) return;
        self.irq_lock.lock();
        defer self.irq_lock.unlock();
        const e = &self.msix_table[entry];
        switch (off % 16) {
            0 => e.addr = (e.addr & 0xffffffff_00000000) | value,
            4 => e.addr = (e.addr & 0xffffffff) | (@as(u64, value) << 32),
            8 => e.data = value,
            12 => e.ctrl = value,
            else => {},
        }
    }

    fn commonRead(self: *Device, off: u16) u32 {
        const s = self.qsel();
        return switch (off) {
            0x00 => self.device_feature_select,
            0x04 => @truncate(self.features >> @intCast(@as(u6, @intCast(self.device_feature_select & 1)) * 32)),
            0x10 => self.config_vector,
            0x12 => self.backend.num_queues,
            0x14 => self.status,
            0x16 => self.queue_select,
            0x18 => self.queues[s].size,
            0x1a => self.queue_vector[s],
            0x1c => @intFromBool(self.qenable[s]),
            0x1e => self.queue_select,
            0x20 => @truncate(self.queues[s].desc),
            0x24 => @truncate(self.queues[s].desc >> 32),
            0x28 => @truncate(self.queues[s].avail),
            0x2c => @truncate(self.queues[s].avail >> 32),
            0x30 => @truncate(self.queues[s].used),
            0x34 => @truncate(self.queues[s].used >> 32),
            else => 0,
        };
    }

    fn commonWrite(self: *Device, off: u16, value: u32) void {
        const s = self.qsel();
        switch (off) {
            0x00 => self.device_feature_select = value,
            0x08 => self.driver_feature_select = value,
            0x0c => {
                const shift: u6 = @intCast(@as(u6, @intCast(self.driver_feature_select & 1)) * 32);
                const mask = @as(u64, 0xffffffff) << shift;
                self.driver_features = (self.driver_features & ~mask) | (@as(u64, value) << shift);
                trace.log("driver_feature[{d}]=0x{x}", .{ self.driver_feature_select, value });
            },
            0x10 => self.config_vector = @truncate(value),
            0x14 => {
                self.status = @truncate(value);
                trace.log("status=0x{x}", .{self.status});
                if (self.status == 0) {
                    self.driver_features = 0;
                    self.irq_lock.lock();
                    self.isr = 0;
                    self.msix_enabled = false;
                    self.irq_lock.unlock();
                    self.resetQueues();
                    if (self.intx_fn) |f| f(self.intx_ptr.?, false); // line low on reset
                }
            },
            0x16 => self.queue_select = @truncate(value),
            // Only accept a valid (nonzero power-of-2, in-range) queue size; an
            // invalid size is parked at 0 so the queue stays inert and can't be
            // driven into the virtq ring math.
            0x18 => {
                const sz: u16 = @truncate(value);
                self.queues[s].size = if (validQueueSize(sz)) sz else 0;
            },
            0x1a => {
                self.irq_lock.lock();
                self.queue_vector[s] = @truncate(value);
                self.irq_lock.unlock();
            },
            0x1c => {
                // Refuse to enable a queue whose size isn't valid (defense in depth
                // with the 0x18 check, so notify never drives a malformed queue).
                self.qenable[s] = (value & 1 != 0) and validQueueSize(self.queues[s].size);
                if (self.qenable[s]) trace.log("queue[{d}] enable size={d} desc=0x{x} avail=0x{x} used=0x{x} vec={d}", .{ s, self.queues[s].size, self.queues[s].desc, self.queues[s].avail, self.queues[s].used, self.queue_vector[s] });
            },
            0x20 => self.queues[s].desc = (self.queues[s].desc & 0xffffffff_00000000) | value,
            0x24 => self.queues[s].desc = (self.queues[s].desc & 0xffffffff) | (@as(u64, value) << 32),
            0x28 => self.queues[s].avail = (self.queues[s].avail & 0xffffffff_00000000) | value,
            0x2c => self.queues[s].avail = (self.queues[s].avail & 0xffffffff) | (@as(u64, value) << 32),
            0x30 => self.queues[s].used = (self.queues[s].used & 0xffffffff_00000000) | value,
            0x34 => self.queues[s].used = (self.queues[s].used & 0xffffffff) | (@as(u64, value) << 32),
            else => {},
        }
    }
};

fn cast(ptr: *anyopaque) *Device {
    return @ptrCast(@alignCast(ptr));
}

fn writeVirtioCap(c: []u8, at: usize, next: u8, len: u8, cfg_type: u8, bar_offset: u32, bar_len: u32) void {
    c[at + 0] = 0x09; // vendor-specific
    c[at + 1] = next;
    c[at + 2] = len;
    c[at + 3] = cfg_type;
    c[at + 4] = 0; // bar 0
    std.mem.writeInt(u32, c[at + 8 ..][0..4], bar_offset, .little);
    std.mem.writeInt(u32, c[at + 12 ..][0..4], bar_len, .little);
}

fn putLE(data: []u8, value: u32) void {
    for (data, 0..) |*b, i| b.* = if (i < 4) @truncate(value >> @intCast(i * 8)) else 0;
}
fn getLE(data: []const u8) u32 {
    var v: u32 = 0;
    for (data, 0..) |b, i| {
        if (i < 4) v |= @as(u32, b) << @intCast(i * 8);
    }
    return v;
}

test "config space exposes a modern virtio function" {
    var ram = [_]u8{0} ** 64;
    const Noop = struct {
        fn notify(p: *anyopaque, d: *Device, q: u16) void {
            _ = p;
            _ = d;
            _ = q;
        }
        fn cfg(p: *anyopaque, o: u16, s: u8) u32 {
            _ = p;
            _ = o;
            _ = s;
            return 0;
        }
    };
    var dummy: u8 = 0;
    var dev = Device.init(.{ .ptr = &dummy, .device_id = 4, .num_queues = 1, .device_features = 0, .notify = Noop.notify, .config_read = Noop.cfg }, .{ .bytes = &ram, .base = 0 });

    try std.testing.expectEqual(@as(u32, 0x1044_1AF4), dev.cfgRead(0, 4));
    try std.testing.expectEqual(@as(u32, 0x40), dev.cfgRead(0x34, 1));

    dev.cfgWrite(0x10, 4, 0xFFFFFFFF);
    try std.testing.expectEqual(@as(u32, 0xFFFF800C), dev.cfgRead(0x10, 4)); // 32 KiB BAR, 64-bit pref
    dev.assignBar(0xC0000000);
    try std.testing.expectEqual(@as(u64, 0xC0000000), dev.barBase());

    dev.commonWrite(0x00, 1);
    try std.testing.expectEqual(@as(u32, 1), dev.commonRead(0x04)); // VERSION_1 in high dword
}

test "device transport state round-trips through export/import" {
    var ram = [_]u8{0} ** 64;
    const Noop = struct {
        fn notify(p: *anyopaque, d: *Device, q: u16) void {
            _ = p;
            _ = d;
            _ = q;
        }
        fn cfg(p: *anyopaque, o: u16, s: u8) u32 {
            _ = p;
            _ = o;
            _ = s;
            return 0;
        }
    };
    const be = Backend{ .ptr = undefined, .device_id = 2, .num_queues = 2, .device_features = 0, .notify = Noop.notify, .config_read = Noop.cfg };
    var src = Device.init(be, .{ .bytes = &ram, .base = 0 });
    // Mutate transport state the way a driver would.
    src.assignBar(0x8000004000);
    src.commonWrite(0x14, 0xb); // status
    src.commonWrite(0x16, 1); // queue_select = 1
    src.commonWrite(0x18, 128); // queue_size
    src.commonWrite(0x1c, 1); // queue_enable
    src.isr = 1;

    const state = src.exportState();

    // A freshly-initialized device with different live pointers imports the state.
    var ram2 = [_]u8{0} ** 64;
    var dst = Device.init(be, .{ .bytes = &ram2, .base = 0x1000 });
    dst.importState(&state);

    try std.testing.expectEqual(@as(u64, 0x8000004000), dst.barBase());
    try std.testing.expectEqual(@as(u8, 0xb), dst.status);
    try std.testing.expectEqual(@as(u16, 128), dst.queues[1].size);
    try std.testing.expect(dst.qenable[1]);
    try std.testing.expectEqual(@as(u8, 1), dst.isr);
    // The live binding (guest memory) is untouched by import.
    try std.testing.expectEqual(@as(u64, 0x1000), dst.mem.base);
}

test "MSI-X delivers a queue completion to the programmed vector" {
    var ram = [_]u8{0} ** 64;
    const Noop = struct {
        fn notify(p: *anyopaque, d: *Device, q: u16) void {
            _ = p;
            _ = d;
            _ = q;
        }
        fn cfg(p: *anyopaque, o: u16, s: u8) u32 {
            _ = p;
            _ = o;
            _ = s;
            return 0;
        }
    };
    var dummy: u8 = 0;
    var dev = Device.init(.{ .ptr = &dummy, .device_id = 2, .num_queues = 1, .device_features = 0, .notify = Noop.notify, .config_read = Noop.cfg }, .{ .bytes = &ram, .base = 0 });

    const Sink = struct {
        addr: u64 = 0,
        data: u32 = 0,
        hits: u32 = 0,
        fn send(p: *anyopaque, addr: u64, data: u32) void {
            const self: *@This() = @ptrCast(@alignCast(p));
            self.addr = addr;
            self.data = data;
            self.hits += 1;
        }
    };
    var sink = Sink{};
    dev.msi_ptr = &sink;
    dev.msi_fn = Sink.send;

    // Driver: program MSI-X table entry 1 (addr/data, unmasked), enable MSI-X,
    // point queue 0 at vector 1.
    dev.barWrite(msix_off + 16 + 0, 4, 0xFEE00000); // entry1 addr_lo
    dev.barWrite(msix_off + 16 + 8, 4, 0x4042); // entry1 data
    dev.barWrite(msix_off + 16 + 12, 4, 0); // entry1 unmask
    dev.cfgWrite(cap_msix + 2, 2, 0x8000); // MSI-X enable
    dev.commonWrite(0x16, 0); // queue_select 0
    dev.commonWrite(0x1a, 1); // queue_msix_vector = 1

    dev.interruptQueue(0);
    try std.testing.expectEqual(@as(u32, 1), sink.hits);
    try std.testing.expectEqual(@as(u64, 0xFEE00000), sink.addr);
    try std.testing.expectEqual(@as(u32, 0x4042), sink.data);

    // Masked vector does not fire.
    dev.barWrite(msix_off + 16 + 12, 4, 1); // mask entry 1
    dev.interruptQueue(0);
    try std.testing.expectEqual(@as(u32, 1), sink.hits);
}

fn irqHammer(dev: *Device, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) dev.interruptQueue(0);
}

test "interruptQueue races safely with MMIO transport writes" {
    // interruptQueue runs on host I/O threads; the MSI-X/ISR/queue-vector writes run
    // on the vCPU thread. They share isr/msix_enabled/queue_vector/msix_table and are
    // synchronized only by irq_lock (the bus lock covers just the vCPU side). This
    // exercises both under contention: it must not deadlock (lock-order regression)
    // and must not trip a bounds/safety check from a torn read.
    var ram = [_]u8{0} ** 64;
    const Noop = struct {
        fn notify(p: *anyopaque, d: *Device, q: u16) void {
            _ = p;
            _ = d;
            _ = q;
        }
        fn cfg(p: *anyopaque, o: u16, s: u8) u32 {
            _ = p;
            _ = o;
            _ = s;
            return 0;
        }
        fn msi(p: *anyopaque, a: u64, d: u32) void {
            _ = p;
            _ = a;
            _ = d;
        }
    };
    var dummy: u8 = 0;
    var dev = Device.init(.{ .ptr = &dummy, .device_id = 2, .num_queues = 1, .device_features = 0, .notify = Noop.notify, .config_read = Noop.cfg }, .{ .bytes = &ram, .base = 0 });
    dev.msi_ptr = &dev;
    dev.msi_fn = Noop.msi;
    dev.msix_enabled = true; // make interruptQueue read msix_table[queue_vector[0]]

    const N = 50_000;
    const t = try std.Thread.spawn(.{}, irqHammer, .{ &dev, N });
    var i: usize = 0;
    while (i < N) : (i += 1) {
        dev.msixWrite(0, @truncate(i)); // races msix_table[0] vs interruptQueue's read
        _ = dev.barRead(isr_off, 4); // races isr clear vs interruptQueue's set
        dev.commonWrite(0x1a, 0); // races queue_vector[0]
    }
    t.join();
    try std.testing.expect(dev.isr <= 1); // isr is only ever set to 1 or cleared to 0
}
