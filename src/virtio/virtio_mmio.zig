//! virtio-mmio transport (virtio 1.x, "modern" version 2). An alternative front
//! end to virtio-pci (virtio.zig) for platforms where MMIO + a wired interrupt is
//! simpler than a PCIe host bridge + MSI - notably aarch64, where the interrupt
//! is a plain GIC SPI. It drives the SAME `virtio.Device` queue state and the
//! SAME `virtio.Backend` devices (blk/net/rng/vsock) and `virtq` datapath; only
//! the register window differs. One device per MMIO region.
//!
//! The device's completion interrupt is level: `interruptQueue` sets the ISR and
//! raises the line (via the legacy irq callback, since MSI-X is never enabled on
//! this transport); the guest reads InterruptStatus and clears it via
//! InterruptACK, which lowers the line. The line itself is delivered by `spi_fn`
//! (an `hv_gic_set_spi` shim on HVF), keeping this file hypervisor-agnostic.

const std = @import("std");
const virtio = @import("virtio.zig");
const virtq = @import("virtq.zig");
const io = @import("../io.zig");
const trace = @import("../common/trace.zig");

pub const region_size = 0x200;

// Register offsets (virtio-mmio, version 2).
const MAGIC = 0x000; // "virt"
const VERSION = 0x004;
const DEVICE_ID = 0x008;
const VENDOR_ID = 0x00c;
const DEVICE_FEATURES = 0x010;
const DEVICE_FEATURES_SEL = 0x014;
const DRIVER_FEATURES = 0x020;
const DRIVER_FEATURES_SEL = 0x024;
const QUEUE_SEL = 0x030;
const QUEUE_NUM_MAX = 0x034;
const QUEUE_NUM = 0x038;
const QUEUE_READY = 0x044;
const QUEUE_NOTIFY = 0x050;
const INTERRUPT_STATUS = 0x060;
const INTERRUPT_ACK = 0x064;
const STATUS = 0x070;
const QUEUE_DESC_LO = 0x080;
const QUEUE_DESC_HI = 0x084;
const QUEUE_DRIVER_LO = 0x090; // avail ring
const QUEUE_DRIVER_HI = 0x094;
const QUEUE_DEVICE_LO = 0x0a0; // used ring
const QUEUE_DEVICE_HI = 0x0a4;
const CONFIG_GEN = 0x0fc;
const CONFIG = 0x100;

const MAGIC_VALUE = 0x7472_6976; // "virt"
const VENDOR = 0x4854_454e; // "NETH"
const QUEUE_NUM_MAXIMUM = 256;

pub const Mmio = struct {
    dev: *virtio.Device,
    base: u64,
    /// GIC SPI interrupt id (absolute INTID) and the shim that asserts it.
    spi_intid: u32,
    spi_fn: ?*const fn (intid: u32, level: bool) void = null,

    queue_sel: u16 = 0,
    dev_feat_sel: u32 = 0,
    drv_feat_sel: u32 = 0,

    /// Bind to a transport-less `virtio.Device`: route its completion interrupt
    /// through our level line (legacy IRQ path; MSI-X stays disabled).
    pub fn init(dev: *virtio.Device, base: u64, spi_intid: u32) Mmio {
        return .{ .dev = dev, .base = base, .spi_intid = spi_intid };
    }

    /// Must be called after the Mmio has a stable address so the device's IRQ
    /// callback can point back at it.
    pub fn attach(self: *Mmio) void {
        self.dev.irq_ptr = self;
        self.dev.irq_fn = raiseThunk;
    }

    pub fn mmioDevice(self: *Mmio) io.MmioDevice {
        return .{ .ptr = self, .base = self.base, .len = region_size, .read_fn = readThunk, .write_fn = writeThunk };
    }

    fn raiseThunk(ptr: *anyopaque) void {
        const self: *Mmio = @ptrCast(@alignCast(ptr));
        if (self.spi_fn) |f| f(self.spi_intid, true); // ISR already set by interruptQueue
    }

    fn qsel(self: *Mmio) usize {
        return @min(self.queue_sel, virtio.max_queues - 1);
    }

    fn readReg(self: *Mmio, off: u64, size: u8) u32 {
        const d = self.dev;
        const s = self.qsel();
        return switch (off) {
            MAGIC => MAGIC_VALUE,
            VERSION => 2,
            DEVICE_ID => d.backend.device_id,
            VENDOR_ID => VENDOR,
            DEVICE_FEATURES => @truncate(d.features >> @intCast((self.dev_feat_sel & 1) * 32)),
            QUEUE_NUM_MAX => QUEUE_NUM_MAXIMUM,
            QUEUE_READY => @intFromBool(d.qenable[s]),
            INTERRUPT_STATUS => d.isr,
            STATUS => d.status,
            CONFIG_GEN => 0,
            else => if (off >= CONFIG) d.backend.config_read(d.backend.ptr, @intCast(off - CONFIG), size) else 0,
        };
    }

    fn writeReg(self: *Mmio, off: u64, value: u32) void {
        const d = self.dev;
        const s = self.qsel();
        switch (off) {
            DEVICE_FEATURES_SEL => self.dev_feat_sel = value,
            DRIVER_FEATURES_SEL => self.drv_feat_sel = value,
            DRIVER_FEATURES => {
                const shift: u6 = @intCast((self.drv_feat_sel & 1) * 32);
                const mask = @as(u64, 0xffff_ffff) << shift;
                d.driver_features = (d.driver_features & ~mask) | (@as(u64, value) << shift);
            },
            QUEUE_SEL => self.queue_sel = @truncate(value),
            QUEUE_NUM => d.queues[s].size = @truncate(value),
            QUEUE_READY => d.qenable[s] = (value & 1) != 0,
            QUEUE_NOTIFY => {
                const q: u16 = @truncate(value);
                if (q < virtio.max_queues and d.qenable[q]) {
                    trace.log("vmmio notify q={d}", .{q});
                    d.backend.notify(d.backend.ptr, d, q);
                }
            },
            INTERRUPT_ACK => {
                d.isr &= ~@as(u8, @truncate(value));
                if (d.isr == 0) if (self.spi_fn) |f| f(self.spi_intid, false); // level low
            },
            STATUS => {
                d.status = @truncate(value);
                if (d.status == 0) self.reset();
            },
            QUEUE_DESC_LO => d.queues[s].desc = (d.queues[s].desc & 0xffff_ffff_0000_0000) | value,
            QUEUE_DESC_HI => d.queues[s].desc = (d.queues[s].desc & 0xffff_ffff) | (@as(u64, value) << 32),
            QUEUE_DRIVER_LO => d.queues[s].avail = (d.queues[s].avail & 0xffff_ffff_0000_0000) | value,
            QUEUE_DRIVER_HI => d.queues[s].avail = (d.queues[s].avail & 0xffff_ffff) | (@as(u64, value) << 32),
            QUEUE_DEVICE_LO => d.queues[s].used = (d.queues[s].used & 0xffff_ffff_0000_0000) | value,
            QUEUE_DEVICE_HI => d.queues[s].used = (d.queues[s].used & 0xffff_ffff) | (@as(u64, value) << 32),
            else => {},
        }
    }

    fn reset(self: *Mmio) void {
        const d = self.dev;
        d.driver_features = 0;
        d.isr = 0;
        for (&d.qenable) |*e| e.* = false;
        if (self.spi_fn) |f| f(self.spi_intid, false);
    }

    fn readThunk(ptr: *anyopaque, offset: u64, data: []u8) void {
        const self: *Mmio = @ptrCast(@alignCast(ptr));
        const v = self.readReg(offset, @intCast(data.len));
        for (data, 0..) |*b, i| b.* = if (i < 4) @truncate(v >> @intCast(i * 8)) else 0;
    }

    fn writeThunk(ptr: *anyopaque, offset: u64, data: []const u8) void {
        const self: *Mmio = @ptrCast(@alignCast(ptr));
        var v: u32 = 0;
        for (data, 0..) |b, i| {
            if (i < 4) v |= @as(u32, b) << @intCast(i * 8);
        }
        self.writeReg(offset, v);
    }
};

// --- tests -----------------------------------------------------------------

const Rng = @import("virtio_rng.zig").Rng;

fn r32(dev: *Mmio, off: u64) u32 {
    var buf = [_]u8{ 0, 0, 0, 0 };
    Mmio.readThunk(dev, off, &buf);
    return std.mem.readInt(u32, &buf, .little);
}
fn w32(dev: *Mmio, off: u64, v: u32) void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    Mmio.writeThunk(dev, off, &buf);
}

test "mmio exposes the virtio identity and device id" {
    var ram = [_]u8{0} ** 64;
    var rng = Rng{};
    var dev = virtio.Device.init(rng.backend(), .{ .bytes = &ram, .base = 0 });
    var m = Mmio.init(&dev, 0, 34);
    try std.testing.expectEqual(@as(u32, 0x7472_6976), r32(&m, MAGIC));
    try std.testing.expectEqual(@as(u32, 2), r32(&m, VERSION));
    try std.testing.expectEqual(@as(u32, 4), r32(&m, DEVICE_ID)); // virtio-rng
    // VERSION_1 lives in the high feature word.
    w32(&m, DEVICE_FEATURES_SEL, 1);
    try std.testing.expectEqual(@as(u32, 1), r32(&m, DEVICE_FEATURES)); // bit 32
}

test "mmio queue kick runs the backend and raises a level interrupt" {
    var ram = [_]u8{0} ** 4096;
    var rng = Rng{};
    var dev = virtio.Device.init(rng.backend(), .{ .bytes = &ram, .base = 0 });

    const Spi = struct {
        var level: bool = false;
        var edges: u32 = 0;
        fn set(intid: u32, lvl: bool) void {
            _ = intid;
            level = lvl;
            edges += 1;
        }
    };
    Spi.level = false;
    Spi.edges = 0;

    var m = Mmio.init(&dev, 0, 34);
    m.spi_fn = Spi.set;
    m.attach();

    // Program queue 0: one device-writable 64-byte buffer at 0x800.
    w32(&m, QUEUE_SEL, 0);
    w32(&m, QUEUE_NUM, 8);
    w32(&m, QUEUE_DESC_LO, 0x0);
    w32(&m, QUEUE_DRIVER_LO, 0x100);
    w32(&m, QUEUE_DEVICE_LO, 0x200);
    w32(&m, QUEUE_READY, 1);
    std.mem.writeInt(u64, ram[0..8], 0x800, .little);
    std.mem.writeInt(u32, ram[8..12], 64, .little);
    std.mem.writeInt(u16, ram[12..14], virtq.DESC_F_WRITE, .little);
    std.mem.writeInt(u16, ram[0x102..][0..2], 1, .little); // avail.idx
    std.mem.writeInt(u16, ram[0x104..][0..2], 0, .little); // ring[0]=desc0

    w32(&m, QUEUE_NOTIFY, 0); // kick

    // Used ring advanced, buffer filled, interrupt asserted.
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ram[0x202..][0..2], .little));
    try std.testing.expectEqual(@as(u32, 1), r32(&m, INTERRUPT_STATUS) & 1);
    try std.testing.expect(Spi.level);

    // ACK clears the status and lowers the line.
    w32(&m, INTERRUPT_ACK, 1);
    try std.testing.expectEqual(@as(u32, 0), r32(&m, INTERRUPT_STATUS));
    try std.testing.expect(!Spi.level);
}
