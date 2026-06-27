//! Port and MMIO dispatch spine. Devices register an address range in either
//! space; the vCPU loop routes each exit to the owning device. Unclaimed
//! accesses follow hardware convention: reads return all-ones, writes are
//! dropped (logged, not fatal), so firmware probing does not kill the vCPU.

const std = @import("std");
const Lock = @import("common/lock.zig").Lock;

pub const max_pio = 16;
pub const max_mmio = 16;

/// A device claiming a port range [base, base+len). `ptr` is its own state.
/// `self_locked` devices serialize their own concurrent access (their handler
/// takes a per-device lock), so the bus releases its lock before calling them -
/// see `Bus.lock`.
pub const PioDevice = struct {
    ptr: *anyopaque,
    base: u16,
    len: u16,
    out_fn: *const fn (ptr: *anyopaque, port: u16, size: u8, value: u32) void,
    in_fn: *const fn (ptr: *anyopaque, port: u16, size: u8) u32,
    self_locked: bool = false,

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
    self_locked: bool = false,

    fn contains(self: MmioDevice, addr: u64) bool {
        return addr >= self.base and addr - self.base < self.len;
    }
};

pub const Bus = struct {
    pio: [max_pio]PioDevice = undefined,
    pio_count: usize = 0,
    mmio: [max_mmio]MmioDevice = undefined,
    mmio_count: usize = 0,
    /// Guards the device registry lookup and serializes dispatch to devices that
    /// are NOT internally thread-safe (the simple ones: PL011, ECAM, the firmware
    /// PIO devices). The registry is immutable after init, so this is only ever
    /// contended for the brief lookup + those small handlers.
    ///
    /// `self_locked` devices (the virtio functions, reached via the PCI BAR window)
    /// take their OWN per-device lock, so the bus RELEASES this lock before calling
    /// them - that is what lets concurrent vCPUs run in different virtio devices at
    /// once, and keeps a virtio notify's host I/O (net TX `send`, a queue drain)
    /// off the global bus lock. Host I/O threads that drive a device directly take
    /// the device's own locks (virtio `dev_lock`/`irq_lock`, backend locks), never
    /// this one.
    lock: Lock = .{},

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
        self.lock.lock();
        for (self.pio[0..self.pio_count]) |d| {
            if (d.contains(port)) {
                if (d.self_locked) self.lock.unlock();
                d.out_fn(d.ptr, port, size, value);
                if (!d.self_locked) self.lock.unlock();
                return;
            }
        }
        self.lock.unlock();
    }

    pub fn pioIn(self: *Bus, port: u16, size: u8) u32 {
        self.lock.lock();
        for (self.pio[0..self.pio_count]) |d| {
            if (d.contains(port)) {
                if (d.self_locked) {
                    self.lock.unlock();
                    return d.in_fn(d.ptr, port, size);
                }
                defer self.lock.unlock();
                return d.in_fn(d.ptr, port, size);
            }
        }
        self.lock.unlock();
        return 0xFFFFFFFF;
    }

    pub fn mmioWrite(self: *Bus, addr: u64, data: []const u8) void {
        self.lock.lock();
        for (self.mmio[0..self.mmio_count]) |d| {
            if (d.contains(addr)) {
                if (d.self_locked) self.lock.unlock();
                d.write_fn(d.ptr, addr - d.base, data);
                if (!d.self_locked) self.lock.unlock();
                return;
            }
        }
        self.lock.unlock();
    }

    pub fn mmioRead(self: *Bus, addr: u64, data: []u8) void {
        self.lock.lock();
        for (self.mmio[0..self.mmio_count]) |d| {
            if (d.contains(addr)) {
                if (d.self_locked) self.lock.unlock();
                d.read_fn(d.ptr, addr - d.base, data);
                if (!d.self_locked) self.lock.unlock();
                return;
            }
        }
        @memset(data, 0xFF);
        self.lock.unlock();
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
