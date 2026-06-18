//! Port/MMIO dispatch spine. Devices register an address range; the vCPU loop
//! routes each I/O exit to the owning device. This is the embryo of the Phase
//! 1.5 exit dispatcher: today it carries port I/O for serial, later the same
//! shape carries MMIO for virtio-pci and the firmware floor.

const std = @import("std");

pub const max_devices = 16;

/// A device claims the port range [base, base+len) and handles reads/writes
/// against it. `ptr` is the device's own state, passed back to the fns.
pub const Device = struct {
    ptr: *anyopaque,
    base: u16,
    len: u16,
    out_fn: *const fn (ptr: *anyopaque, port: u16, size: u8, value: u32) void,
    in_fn: *const fn (ptr: *anyopaque, port: u16, size: u8) u32,

    fn contains(self: Device, port: u16) bool {
        return port >= self.base and port < self.base + self.len;
    }
};

pub const Bus = struct {
    devices: [max_devices]Device = undefined,
    count: usize = 0,

    pub fn add(self: *Bus, dev: Device) error{BusFull}!void {
        if (self.count == max_devices) return error.BusFull;
        self.devices[self.count] = dev;
        self.count += 1;
    }

    pub fn out(self: *Bus, port: u16, size: u8, value: u32) void {
        for (self.devices[0..self.count]) |d| {
            if (d.contains(port)) {
                d.out_fn(d.ptr, port, size, value);
                return;
            }
        }
        std.debug.print("[nether] unhandled OUT port=0x{x} size={d} value=0x{x}\n", .{ port, size, value });
    }

    pub fn in(self: *Bus, port: u16, size: u8) u32 {
        for (self.devices[0..self.count]) |d| {
            if (d.contains(port)) return d.in_fn(d.ptr, port, size);
        }
        std.debug.print("[nether] unhandled IN port=0x{x} size={d}\n", .{ port, size });
        return 0;
    }
};

test "bus routes by port range and reports misses" {
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
    try bus.add(.{ .ptr = &probe, .base = 0x100, .len = 4, .out_fn = Probe.out, .in_fn = Probe.in });

    bus.out(0x101, 1, 0x42);
    try std.testing.expectEqual(@as(u32, 0x42), probe.last);
    try std.testing.expectEqual(@as(u32, 0xAB), bus.in(0x102, 1));
    // Out-of-range access is a no-op miss, not a crash.
    bus.out(0x200, 1, 0x99);
    try std.testing.expectEqual(@as(u32, 0x42), probe.last);
}
