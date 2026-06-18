//! Port and MMIO dispatch spine. Devices register an address range in either
//! space; the vCPU loop routes each exit to the owning device. Unclaimed
//! accesses follow hardware convention: reads return all-ones, writes are
//! dropped (logged, not fatal), so firmware probing does not kill the vCPU.

const std = @import("std");

pub const max_pio = 16;
pub const max_mmio = 16;

/// A device claiming a port range [base, base+len). `ptr` is its own state.
pub const PioDevice = struct {
    ptr: *anyopaque,
    base: u16,
    len: u16,
    out_fn: *const fn (ptr: *anyopaque, port: u16, size: u8, value: u32) void,
    in_fn: *const fn (ptr: *anyopaque, port: u16, size: u8) u32,

    fn contains(self: PioDevice, port: u16) bool {
        return port >= self.base and port - self.base < self.len;
    }
};

/// A device claiming an MMIO range [base, base+len). Handlers receive the
/// offset within the device, not the absolute address.
pub const MmioDevice = struct {
    ptr: *anyopaque,
    base: u64,
    len: u64,
    read_fn: *const fn (ptr: *anyopaque, offset: u64, data: []u8) void,
    write_fn: *const fn (ptr: *anyopaque, offset: u64, data: []const u8) void,

    fn contains(self: MmioDevice, addr: u64) bool {
        return addr >= self.base and addr - self.base < self.len;
    }
};

pub const Bus = struct {
    pio: [max_pio]PioDevice = undefined,
    pio_count: usize = 0,
    mmio: [max_mmio]MmioDevice = undefined,
    mmio_count: usize = 0,

    pub fn addPio(self: *Bus, dev: PioDevice) error{BusFull}!void {
        if (self.pio_count == max_pio) return error.BusFull;
        self.pio[self.pio_count] = dev;
        self.pio_count += 1;
    }

    pub fn addMmio(self: *Bus, dev: MmioDevice) error{BusFull}!void {
        if (self.mmio_count == max_mmio) return error.BusFull;
        self.mmio[self.mmio_count] = dev;
        self.mmio_count += 1;
    }

    pub fn pioOut(self: *Bus, port: u16, size: u8, value: u32) void {
        for (self.pio[0..self.pio_count]) |d| {
            if (d.contains(port)) {
                d.out_fn(d.ptr, port, size, value);
                return;
            }
        }
        std.debug.print("[nether] unclaimed PIO out port=0x{x} size={d}\n", .{ port, size });
    }

    pub fn pioIn(self: *Bus, port: u16, size: u8) u32 {
        for (self.pio[0..self.pio_count]) |d| {
            if (d.contains(port)) return d.in_fn(d.ptr, port, size);
        }
        std.debug.print("[nether] unclaimed PIO in port=0x{x} size={d}\n", .{ port, size });
        return 0xFFFFFFFF;
    }

    pub fn mmioWrite(self: *Bus, addr: u64, data: []const u8) void {
        for (self.mmio[0..self.mmio_count]) |d| {
            if (d.contains(addr)) {
                d.write_fn(d.ptr, addr - d.base, data);
                return;
            }
        }
        std.debug.print("[nether] unclaimed MMIO write @0x{x} len={d}\n", .{ addr, data.len });
    }

    pub fn mmioRead(self: *Bus, addr: u64, data: []u8) void {
        for (self.mmio[0..self.mmio_count]) |d| {
            if (d.contains(addr)) {
                d.read_fn(d.ptr, addr - d.base, data);
                return;
            }
        }
        @memset(data, 0xFF);
        std.debug.print("[nether] unclaimed MMIO read @0x{x} len={d}\n", .{ addr, data.len });
    }
};

test "pio bus routes by range and reports misses" {
    const Probe = struct {
        last: u32 = 0,
        fn out(ptr: *anyopaque, port: u16, size: u8, value: u32) void {
            _ = port;
            _ = size;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.last = value;
        }
        fn in(ptr: *anyopaque, port: u16, size: u8) u32 {
            _ = ptr;
            _ = port;
            _ = size;
            return 0xAB;
        }
    };
    var probe = Probe{};
    var bus = Bus{};
    try bus.addPio(.{ .ptr = &probe, .base = 0x100, .len = 4, .out_fn = Probe.out, .in_fn = Probe.in });

    bus.pioOut(0x101, 1, 0x42);
    try std.testing.expectEqual(@as(u32, 0x42), probe.last);
    try std.testing.expectEqual(@as(u32, 0xAB), bus.pioIn(0x102, 1));
    // Unclaimed port: all-ones, not a crash.
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), bus.pioIn(0x200, 1));
}

test "mmio bus routes reads and writes by range" {
    const Mem = struct {
        store: [4]u8 = .{ 0, 0, 0, 0 },
        fn read(ptr: *anyopaque, offset: u64, data: []u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const o: usize = @intCast(offset);
            for (data, 0..) |*b, i| b.* = self.store[o + i];
        }
        fn write(ptr: *anyopaque, offset: u64, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const o: usize = @intCast(offset);
            for (data, 0..) |b, i| self.store[o + i] = b;
        }
    };
    var mem = Mem{};
    var bus = Bus{};
    try bus.addMmio(.{ .ptr = &mem, .base = 0xD000_0000, .len = 4, .read_fn = Mem.read, .write_fn = Mem.write });

    bus.mmioWrite(0xD000_0001, &[_]u8{0xEE});
    try std.testing.expectEqual(@as(u8, 0xEE), mem.store[1]);

    var buf = [_]u8{0};
    bus.mmioRead(0xD000_0001, &buf);
    try std.testing.expectEqual(@as(u8, 0xEE), buf[0]);

    // Unclaimed MMIO read: all-ones.
    var miss = [_]u8{ 0, 0 };
    bus.mmioRead(0xFF00_0000, &miss);
    try std.testing.expectEqual(@as(u8, 0xFF), miss[0]);
}
