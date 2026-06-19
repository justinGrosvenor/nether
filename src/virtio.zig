//! virtio-pci modern transport (virtio 1.x). Presents a virtio device as a PCI
//! function whose BAR0 holds the common/notify/isr/device-config structures the
//! driver drives. Feature negotiation and queue programming run through the
//! common config; a write to the notify region kicks a queue, which the backend
//! processes via virtq.zig.
//!
//! A backend (e.g. rng) plugs in via the Backend vtable. Interrupt delivery is
//! left to a callback so it can be MSI-X (signalMsi) once that is wired; the ISR
//! byte is maintained for the legacy path.

const std = @import("std");
const virtq = @import("virtq.zig");

pub const max_queues = 8;

// device_status bits
pub const ACKNOWLEDGE = 1;
pub const DRIVER = 2;
pub const DRIVER_OK = 4;
pub const FEATURES_OK = 8;

pub const VIRTIO_F_VERSION_1: u64 = 1 << 32;
const MSI_NO_VECTOR: u16 = 0xffff;

// BAR0 region offsets.
const bar_size = 0x4000;
const common_off = 0x0000;
const isr_off = 0x1000;
const notify_off = 0x2000;
const device_off = 0x3000;

/// A virtio device backend. `notify` is called when queue `q` is kicked.
pub const Backend = struct {
    ptr: *anyopaque,
    device_id: u16, // virtio device type (rng = 4)
    num_queues: u16,
    device_features: u64, // beyond VIRTIO_F_VERSION_1
    notify: *const fn (ptr: *anyopaque, dev: *Device, q: u16) void,
    config_read: *const fn (ptr: *anyopaque, off: u16, size: u8) u32,
};

pub const Device = struct {
    backend: Backend,
    mem: virtq.GuestMem,
    features: u64, // device-offered features

    config: [256]u8 = undefined, // PCI config space
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

    irq_ptr: ?*anyopaque = null,
    irq_fn: ?*const fn (ptr: *anyopaque) void = null,

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
        std.mem.writeInt(u16, c[0..2], 0x1af4, .little); // vendor: Red Hat / virtio
        std.mem.writeInt(u16, c[2..4], 0x1040 + self.backend.device_id, .little); // modern device id
        std.mem.writeInt(u16, c[6..8], 0x0010, .little); // status: capabilities list
        c[8] = 0x01; // revision (>=1 means modern)
        c[0x0e] = 0x00; // header type 0
        std.mem.writeInt(u16, c[0x2c..0x2e], 0x1af4, .little); // subsystem vendor
        std.mem.writeInt(u16, c[0x2e..0x30], self.backend.device_id, .little); // subsystem device
        c[0x34] = 0x40; // capabilities pointer

        writeCap(c, 0x40, 0x50, 16, 1, common_off, 0x1000); // COMMON_CFG
        writeCap(c, 0x50, 0x64, 20, 2, notify_off, 0x1000); // NOTIFY_CFG (+ multiplier below)
        std.mem.writeInt(u32, c[0x50 + 16 ..][0..4], 0, .little); // notify_off_multiplier = 0
        writeCap(c, 0x64, 0x74, 16, 3, isr_off, 0x1000); // ISR_CFG
        writeCap(c, 0x74, 0x00, 16, 4, device_off, 0x1000); // DEVICE_CFG
    }

    fn qsel(self: *Device) usize {
        return @min(self.queue_select, max_queues - 1);
    }

    pub fn queue(self: *Device, i: u16) *virtq.Virtqueue {
        return &self.queues[@min(i, max_queues - 1)];
    }
    pub fn memory(self: *Device) virtq.GuestMem {
        return self.mem;
    }
    pub fn raiseInterrupt(self: *Device) void {
        self.isr |= 1;
        if (self.irq_fn) |f| f(self.irq_ptr.?);
    }

    // --- PCI config space ---------------------------------------------------

    pub fn cfgRead(self: *Device, reg: u16, size: u8) u32 {
        if (size == 4 and reg == 0x10) return if (self.probe_lo) 0xFFFFC00C else (self.bar0 & 0xFFFFFFF0) | 0x0C;
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
            }
        } else if (size == 4 and reg == 0x14) {
            if (value == 0xFFFFFFFF) self.probe_hi = true else {
                self.bar1 = value;
                self.probe_hi = false;
            }
        }
        // Command register and other writable bits are accepted but unmodeled.
    }

    pub fn barBase(self: *Device) u64 {
        return (@as(u64, self.bar1) << 32) | (self.bar0 & 0xFFFFFFF0);
    }

    // --- BAR MMIO -----------------------------------------------------------

    pub fn barRead(self: *Device, off: u64, size: u8) u32 {
        if (off < isr_off) return self.commonRead(@intCast(off));
        if (off < notify_off) {
            const v = self.isr;
            self.isr = 0; // read-to-clear
            return v;
        }
        if (off < device_off) return 0; // notify region reads as 0
        return self.backend.config_read(self.backend.ptr, @intCast(off - device_off), size);
    }

    pub fn barWrite(self: *Device, off: u64, size: u8, value: u32) void {
        if (off < isr_off) {
            self.commonWrite(@intCast(off), value);
        } else if (off >= notify_off and off < device_off) {
            const q: u16 = @truncate(value); // notify_off_multiplier 0: value is the queue index
            if (q < max_queues and self.qenable[q]) self.backend.notify(self.backend.ptr, self, q);
        }
        _ = size;
    }

    fn commonRead(self: *Device, off: u16) u32 {
        const s = self.qsel();
        return switch (off) {
            0x00 => self.device_feature_select,
            0x04 => @truncate(self.features >> @intCast(@as(u6, @intCast(self.device_feature_select & 1)) * 32)),
            0x10 => MSI_NO_VECTOR,
            0x12 => self.backend.num_queues,
            0x14 => self.status,
            0x16 => self.queue_select,
            0x18 => self.queues[s].size,
            0x1a => MSI_NO_VECTOR,
            0x1c => @intFromBool(self.qenable[s]),
            0x1e => self.queue_select, // notify_off
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
            },
            0x14 => {
                self.status = @truncate(value);
                if (self.status == 0) {
                    self.driver_features = 0;
                    self.isr = 0;
                    self.resetQueues();
                }
            },
            0x16 => self.queue_select = @truncate(value),
            0x18 => self.queues[s].size = @truncate(value),
            0x1c => self.qenable[s] = value & 1 != 0,
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

fn writeCap(c: []u8, at: usize, next: u8, len: u8, cfg_type: u8, bar_offset: u32, bar_len: u32) void {
    c[at + 0] = 0x09; // PCI vendor-specific capability
    c[at + 1] = next;
    c[at + 2] = len;
    c[at + 3] = cfg_type;
    c[at + 4] = 0; // bar 0
    std.mem.writeInt(u32, c[at + 8 ..][0..4], bar_offset, .little);
    std.mem.writeInt(u32, c[at + 12 ..][0..4], bar_len, .little);
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

    try std.testing.expectEqual(@as(u32, 0x1044_1AF4), dev.cfgRead(0, 4)); // vendor + device (rng)
    try std.testing.expectEqual(@as(u32, 0x40), dev.cfgRead(0x34, 1)); // cap pointer

    // BAR sizing: write all-ones, read back the size mask for a 16 KiB BAR.
    dev.cfgWrite(0x10, 4, 0xFFFFFFFF);
    try std.testing.expectEqual(@as(u32, 0xFFFFC00C), dev.cfgRead(0x10, 4));
    dev.cfgWrite(0x10, 4, 0xC0000000);
    try std.testing.expectEqual(@as(u64, 0xC0000000), dev.barBase());

    // VERSION_1 is offered in the high feature dword.
    dev.commonWrite(0x00, 1); // device_feature_select = 1
    try std.testing.expectEqual(@as(u32, 1), dev.commonRead(0x04)); // bit 32
}
