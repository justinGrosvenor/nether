//! virtio-rng backend: on a queue kick, fill each device-writable buffer with
//! bytes and publish them to the used ring. The first real device on the
//! virtio-pci transport, and the smallest, so it validates the whole path.
//!
//! Bytes come from a deterministic PCG so tests are reproducible. A production
//! entropy source should reseed `state` from the host (getrandom); the device
//! contract (fill writable buffers) is unchanged.

const std = @import("std");
const virtio = @import("virtio.zig");
const virtq = @import("virtq.zig");

pub const Rng = struct {
    state: u64 = 0x9e3779b97f4a7c15,

    pub fn backend(self: *Rng) virtio.Backend {
        return .{
            .ptr = self,
            .device_id = 4, // virtio rng
            .num_queues = 1,
            .device_features = 0,
            .notify = onNotify,
            .config_read = noConfig,
        };
    }

    fn onNotify(ptr: *anyopaque, dev: *virtio.Device, q: u16) void {
        const self: *Rng = @ptrCast(@alignCast(ptr));
        const mem = dev.memory();
        const vq = dev.queue(q);
        while (vq.next(mem)) |head| {
            var it = vq.chain(mem, head);
            var written: u32 = 0;
            while (it.next()) |buf| {
                if (buf.writable) {
                    if (mem.slice(buf.addr, buf.len)) |s| {
                        self.fill(s);
                        written += @intCast(s.len);
                    }
                }
            }
            vq.complete(mem, head, written);
        }
        dev.interruptQueue(q);
    }

    fn fill(self: *Rng, s: []u8) void {
        for (s) |*b| {
            self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
            b.* = @truncate(self.state >> 33);
        }
    }

    fn noConfig(ptr: *anyopaque, off: u16, size: u8) u32 {
        _ = ptr;
        _ = off;
        _ = size;
        return 0;
    }
};

test "rng fills a writable buffer and publishes to used" {
    var ram = [_]u8{0} ** 4096;
    var rng = Rng{};
    var dev = virtio.Device.init(rng.backend(), .{ .bytes = &ram, .base = 0 });

    // Driver programs queue 0 through the BAR common config.
    dev.barWrite(0x16, 2, 0); // queue_select = 0
    dev.barWrite(0x18, 2, 4); // queue_size = 4
    dev.barWrite(0x20, 4, 0x0); // queue_desc = 0x0
    dev.barWrite(0x24, 4, 0x0);
    dev.barWrite(0x28, 4, 0x100); // queue_driver (avail) = 0x100
    dev.barWrite(0x2c, 4, 0x0);
    dev.barWrite(0x30, 4, 0x200); // queue_device (used) = 0x200
    dev.barWrite(0x34, 4, 0x0);
    dev.barWrite(0x1c, 2, 1); // queue_enable = 1

    // One device-writable buffer of 64 bytes at 0x800.
    std.mem.writeInt(u64, ram[0..8], 0x800, .little); // desc[0].addr
    std.mem.writeInt(u32, ram[8..12], 64, .little); // desc[0].len
    std.mem.writeInt(u16, ram[12..14], virtq.DESC_F_WRITE, .little); // flags
    std.mem.writeInt(u16, ram[0x102..][0..2], 1, .little); // avail.idx = 1
    std.mem.writeInt(u16, ram[0x104..][0..2], 0, .little); // avail.ring[0] = desc 0

    // Kick the queue.
    dev.barWrite(0x2000, 4, 0);

    // Used ring advanced, full length reported, buffer written, interrupt raised.
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ram[0x202..][0..2], .little));
    try std.testing.expectEqual(@as(u32, 64), std.mem.readInt(u32, ram[0x208..][0..4], .little));
    var nonzero = false;
    for (ram[0x800..0x840]) |b| {
        if (b != 0) nonzero = true;
    }
    try std.testing.expect(nonzero);
    try std.testing.expect(dev.isr & 1 != 0);
}
