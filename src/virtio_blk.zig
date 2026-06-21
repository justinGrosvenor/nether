//! virtio-blk backend. On a queue kick it walks each request chain
//! (header, data segments, status byte) and serves it from a flat backing store
//! (a host-mmap'd disk image in the live VMM, an in-memory slice in tests).
//!
//! Only direct descriptor chains are handled; we do not offer
//! VIRTIO_RING_F_INDIRECT_DESC, so the Linux driver uses direct chains. All
//! guest and disk accesses are bounds-checked.

const std = @import("std");
const virtio = @import("virtio.zig");
const virtq = @import("virtq.zig");
const trace = @import("trace.zig");

pub const Blk = struct {
    disk: []u8,

    const T_IN = 0; // read from disk into guest
    const T_OUT = 1; // write guest into disk
    const T_FLUSH = 4;
    const T_GET_ID = 8;

    const S_OK = 0;
    const S_IOERR = 1;
    const S_UNSUPP = 2;

    const SECTOR = 512;
    const max_segs = 130; // header + up to 128 data + status

    pub fn backend(self: *Blk) virtio.Backend {
        return .{
            .ptr = self,
            .device_id = 2, // virtio block
            .num_queues = 1,
            .device_features = 0,
            .notify = onNotify,
            .config_read = configRead,
        };
    }

    /// virtio_blk_config: capacity in 512-byte sectors at offset 0 (u64).
    fn configRead(ptr: *anyopaque, off: u16, size: u8) u32 {
        _ = size;
        const self: *Blk = @ptrCast(@alignCast(ptr));
        const cap: u64 = self.disk.len / SECTOR;
        return switch (off) {
            0 => @truncate(cap),
            4 => @truncate(cap >> 32),
            else => 0,
        };
    }

    fn onNotify(ptr: *anyopaque, dev: *virtio.Device, q: u16) void {
        const self: *Blk = @ptrCast(@alignCast(ptr));
        const mem = dev.memory();
        const vq = dev.queue(q);
        while (vq.next(mem)) |head| {
            trace.log("blk head={d}", .{head});
            const written = self.handle(mem, vq, head);
            vq.complete(mem, head, written);
        }
        dev.interruptQueue(q);
    }

    fn handle(self: *Blk, mem: virtq.GuestMem, vq: *virtq.Virtqueue, head: u16) u32 {
        var bufs: [max_segs]virtq.Buffer = undefined;
        var n: usize = 0;
        var it = vq.chain(mem, head);
        while (it.next()) |b| {
            if (n < bufs.len) bufs[n] = b;
            n += 1;
        }
        if (n < 2 or n > bufs.len) return 0; // need header + status, and bounded

        const hdr = mem.slice(bufs[0].addr, 16) orelse return 0;
        const req_type = std.mem.readInt(u32, hdr[0..4], .little);
        const sector = std.mem.readInt(u64, hdr[8..16], .little);
        const status = bufs[n - 1];

        var ok = true;
        var data_written: u32 = 0;
        const cap: u64 = self.disk.len;
        // The sector is guest-controlled: compute the byte offset with an overflow
        // check (sector*512 can wrap u64, or trap in safe builds). On overflow we
        // park `off` past capacity so every bounds check below fails -> S_IOERR.
        var off: u64 = std.math.mul(u64, sector, SECTOR) catch std.math.maxInt(u64);

        switch (req_type) {
            T_IN => for (bufs[1 .. n - 1]) |d| {
                const dst = mem.slice(d.addr, d.len) orelse {
                    ok = false;
                    break;
                };
                // Overflow-safe: never compute off+d.len; check against room left.
                if (off <= cap and d.len <= cap - off) {
                    const o: usize = @intCast(off);
                    @memcpy(dst, self.disk[o..][0..d.len]);
                    data_written +|= d.len;
                } else {
                    @memset(dst, 0);
                    ok = false;
                }
                off +|= d.len;
            },
            T_OUT => for (bufs[1 .. n - 1]) |d| {
                const src = mem.slice(d.addr, d.len) orelse {
                    ok = false;
                    break;
                };
                if (off <= cap and d.len <= cap - off) {
                    const o: usize = @intCast(off);
                    @memcpy(self.disk[o..][0..d.len], src);
                } else ok = false;
                off +|= d.len;
            },
            T_GET_ID => for (bufs[1 .. n - 1]) |d| {
                const dst = mem.slice(d.addr, d.len) orelse {
                    ok = false;
                    break;
                };
                const id = "nether-blk";
                const m = @min(dst.len, id.len);
                @memcpy(dst[0..m], id[0..m]);
                if (dst.len > m) @memset(dst[m..], 0);
                data_written +|= @intCast(@min(dst.len, std.math.maxInt(u32)));
            },
            T_FLUSH => {}, // backing store is memory; nothing to flush
            else => ok = false,
        }

        if (mem.slice(status.addr, 1)) |s| s[0] = if (ok) S_OK else S_IOERR;
        trace.log("blk type={d} sector={d} bufs={d} written={d} ok={}", .{ req_type, sector, n, data_written, ok });
        return data_written +| 1; // device-written bytes: data + status
    }
};

test "blk read serves a sector and reports OK" {
    var disk = [_]u8{0} ** 2048;
    for (disk[0..512], 0..) |*b, i| b.* = @truncate(i); // sector 0 pattern

    var ram = [_]u8{0} ** 4096;
    var blk = Blk{ .disk = &disk };
    var dev = virtio.Device.init(blk.backend(), .{ .bytes = &ram, .base = 0 });

    // capacity = 2048/512 = 4 sectors
    try std.testing.expectEqual(@as(u32, 4), dev.barRead(0x3000, 4));

    dev.barWrite(0x16, 2, 0); // queue_select 0
    dev.barWrite(0x18, 2, 8); // queue_size
    dev.barWrite(0x20, 4, 0x0); // desc
    dev.barWrite(0x28, 4, 0x100); // avail
    dev.barWrite(0x30, 4, 0x200); // used
    dev.barWrite(0x1c, 2, 1); // enable

    // chain: header(16) -> data(512, write) -> status(1, write)
    writeDesc(&ram, 0, 0x400, 16, virtq.DESC_F_NEXT, 1);
    writeDesc(&ram, 1, 0x600, 512, virtq.DESC_F_NEXT | virtq.DESC_F_WRITE, 2);
    writeDesc(&ram, 2, 0x900, 1, virtq.DESC_F_WRITE, 0);
    // header: type=IN(0), sector=0
    std.mem.writeInt(u32, ram[0x400..][0..4], 0, .little);
    std.mem.writeInt(u64, ram[0x408..][0..8], 0, .little);
    std.mem.writeInt(u16, ram[0x102..][0..2], 1, .little); // avail.idx
    std.mem.writeInt(u16, ram[0x104..][0..2], 0, .little); // ring[0]=desc0

    dev.barWrite(0x2000, 4, 0); // kick

    try std.testing.expectEqualSlices(u8, disk[0..512], ram[0x600..0x800]); // sector delivered
    try std.testing.expectEqual(@as(u8, 0), ram[0x900]); // status OK
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ram[0x202..][0..2], .little)); // used advanced
    try std.testing.expectEqual(@as(u32, 513), std.mem.readInt(u32, ram[0x208..][0..4], .little)); // 512 + status
}

test "blk write updates the disk" {
    var disk = [_]u8{0} ** 2048;
    var ram = [_]u8{0} ** 4096;
    var blk = Blk{ .disk = &disk };
    var dev = virtio.Device.init(blk.backend(), .{ .bytes = &ram, .base = 0 });

    dev.barWrite(0x16, 2, 0);
    dev.barWrite(0x18, 2, 8);
    dev.barWrite(0x28, 4, 0x100);
    dev.barWrite(0x30, 4, 0x200);
    dev.barWrite(0x1c, 2, 1);

    writeDesc(&ram, 0, 0x400, 16, virtq.DESC_F_NEXT, 1);
    writeDesc(&ram, 1, 0x600, 512, virtq.DESC_F_NEXT, 2); // OUT data is device-readable
    writeDesc(&ram, 2, 0x900, 1, virtq.DESC_F_WRITE, 0);
    std.mem.writeInt(u32, ram[0x400..][0..4], 1, .little); // type=OUT
    std.mem.writeInt(u64, ram[0x408..][0..8], 1, .little); // sector 1
    for (ram[0x600..0x800], 0..) |*b, i| b.* = @truncate(i ^ 0x5a);
    std.mem.writeInt(u16, ram[0x102..][0..2], 1, .little);
    std.mem.writeInt(u16, ram[0x104..][0..2], 0, .little);

    dev.barWrite(0x2000, 4, 0);

    try std.testing.expectEqualSlices(u8, ram[0x600..0x800], disk[512..1024]); // sector 1 written
    try std.testing.expectEqual(@as(u8, 0), ram[0x900]);
}

fn writeDesc(buf: []u8, idx: usize, addr: u64, len: u32, flags: u16, nxt: u16) void {
    const a = idx * 16;
    std.mem.writeInt(u64, buf[a..][0..8], addr, .little);
    std.mem.writeInt(u32, buf[a + 8 ..][0..4], len, .little);
    std.mem.writeInt(u16, buf[a + 12 ..][0..2], flags, .little);
    std.mem.writeInt(u16, buf[a + 14 ..][0..2], nxt, .little);
}

test "blk rejects an overflowing sector without crashing" {
    var disk = [_]u8{0} ** 2048;
    var ram = [_]u8{0} ** 4096;
    var blk = Blk{ .disk = &disk };
    var dev = virtio.Device.init(blk.backend(), .{ .bytes = &ram, .base = 0 });

    dev.barWrite(0x16, 2, 0); // queue_select 0
    dev.barWrite(0x18, 2, 8); // queue_size
    dev.barWrite(0x20, 4, 0x0); // desc
    dev.barWrite(0x28, 4, 0x100); // avail
    dev.barWrite(0x30, 4, 0x200); // used
    dev.barWrite(0x1c, 2, 1); // enable

    writeDesc(&ram, 0, 0x400, 16, virtq.DESC_F_NEXT, 1);
    writeDesc(&ram, 1, 0x600, 512, virtq.DESC_F_NEXT | virtq.DESC_F_WRITE, 2);
    writeDesc(&ram, 2, 0x900, 1, virtq.DESC_F_WRITE, 0);
    std.mem.writeInt(u32, ram[0x400..][0..4], 0, .little); // type=IN
    std.mem.writeInt(u64, ram[0x408..][0..8], 0xFFFF_FFFF_FFFF_FFFF, .little); // sector*512 overflows u64
    std.mem.writeInt(u16, ram[0x102..][0..2], 1, .little); // avail.idx
    std.mem.writeInt(u16, ram[0x104..][0..2], 0, .little); // ring[0]=desc0

    dev.barWrite(0x2000, 4, 0); // kick - must not panic
    try std.testing.expectEqual(@as(u8, 1), ram[0x900]); // S_IOERR, request rejected
}

test "virtio refuses invalid queue sizes" {
    var disk = [_]u8{0} ** 512;
    var ram = [_]u8{0} ** 1024;
    var blk = Blk{ .disk = &disk };
    var dev = virtio.Device.init(blk.backend(), .{ .bytes = &ram, .base = 0 });
    dev.barWrite(0x16, 2, 0); // queue_select 0

    dev.barWrite(0x18, 2, 0); // size 0 -> rejected (parked at 0)
    try std.testing.expectEqual(@as(u16, 0), dev.queue(0).size);
    dev.barWrite(0x1c, 2, 1); // enable refused while size invalid
    try std.testing.expectEqual(@as(u32, 0), dev.barRead(0x1c, 2));

    dev.barWrite(0x18, 2, 3); // non-power-of-2 -> rejected
    try std.testing.expectEqual(@as(u16, 0), dev.queue(0).size);
    dev.barWrite(0x18, 2, 1024); // above max -> rejected
    try std.testing.expectEqual(@as(u16, 0), dev.queue(0).size);

    dev.barWrite(0x18, 2, 8); // valid power-of-2
    try std.testing.expectEqual(@as(u16, 8), dev.queue(0).size);
    dev.barWrite(0x1c, 2, 1); // now enable succeeds
    try std.testing.expectEqual(@as(u32, 1), dev.barRead(0x1c, 2));
}
