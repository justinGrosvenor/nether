//! PCIe host bridge via ECAM. Decodes memory-mapped config accesses in the ECAM
//! window (memmap.ecam_base) into (bus, device, function, register) and routes
//! them to registered functions. Unclaimed config space reads back all-ones, so
//! a guest scanning the bus sees absent devices, not garbage.
//!
//! This is the foundation the virtio-pci transport sits on; for now it serves an
//! empty bus 0, which is exactly what a PVH guest expects to find via MCFG.

const std = @import("std");
const io = @import("io.zig");
const memmap = @import("memmap.zig");
const trace = @import("trace.zig");

pub const max_functions = 16;

/// A PCI function: 4 KiB of config space behind read/write callbacks. `reg` is
/// the byte offset within the function's config space; `size` is 1, 2, or 4.
pub const Function = struct {
    ptr: *anyopaque,
    dev: u5,
    func: u3,
    read: *const fn (ptr: *anyopaque, reg: u16, size: u8) u32,
    write: *const fn (ptr: *anyopaque, reg: u16, size: u8, value: u32) void,
};

pub const Host = struct {
    functions: [max_functions]Function = undefined,
    count: usize = 0,
    /// ECAM window placement. Defaults to the x86 memory map; aarch64 overrides
    /// it (the bus decode is `offset >> 20`, so size must cover the bus range).
    ecam_base: u64 = memmap.ecam_base,
    ecam_size: u64 = memmap.ecam_size,

    pub fn addFunction(self: *Host, f: Function) error{Full}!void {
        if (self.count == max_functions) return error.Full;
        self.functions[self.count] = f;
        self.count += 1;
    }

    pub fn mmioDevice(self: *Host) io.MmioDevice {
        return .{
            .ptr = self,
            .base = self.ecam_base,
            .len = self.ecam_size,
            .read_fn = onRead,
            .write_fn = onWrite,
        };
    }

    fn find(self: *Host, dev: u5, func: u3) ?*const Function {
        for (self.functions[0..self.count]) |*f| {
            if (f.dev == dev and f.func == func) return f;
        }
        return null;
    }

    fn onRead(ptr: *anyopaque, offset: u64, data: []u8) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        var value: u32 = 0xFFFF_FFFF;
        const bus = (offset >> 20) & 0xff;
        if (bus == 0) {
            const dev: u5 = @intCast((offset >> 15) & 0x1f);
            const func: u3 = @intCast((offset >> 12) & 0x7);
            const reg: u16 = @intCast(offset & 0xfff);
            if (self.find(dev, func)) |f| {
                value = f.read(f.ptr, reg, @intCast(data.len));
                trace.log("cfg rd {d}.{d} reg=0x{x} -> 0x{x}", .{ dev, func, reg, value });
            }
        }
        putLE(data, value);
    }

    fn onWrite(ptr: *anyopaque, offset: u64, data: []const u8) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        const bus = (offset >> 20) & 0xff;
        if (bus != 0) return;
        const dev: u5 = @intCast((offset >> 15) & 0x1f);
        const func: u3 = @intCast((offset >> 12) & 0x7);
        const reg: u16 = @intCast(offset & 0xfff);
        if (self.find(dev, func)) |f| {
            const value = getLE(data);
            trace.log("cfg wr {d}.{d} reg=0x{x} <- 0x{x}", .{ dev, func, reg, value });
            f.write(f.ptr, reg, @intCast(data.len), value);
        }
    }
};

fn putLE(data: []u8, value: u32) void {
    for (data, 0..) |*b, i| b.* = if (i < 4) @truncate(value >> @intCast(i * 8)) else 0xFF;
}

fn getLE(data: []const u8) u32 {
    var v: u32 = 0;
    for (data, 0..) |b, i| {
        if (i < 4) v |= @as(u32, b) << @intCast(i * 8);
    }
    return v;
}

test "ECAM decodes and routes config accesses" {
    const Fake = struct {
        last_reg: u16 = 0,
        fn read(ptr: *anyopaque, reg: u16, size: u8) u32 {
            _ = size;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.last_reg = reg;
            return if (reg == 0) 0x1042_1AF4 else 0; // virtio-blk vendor/device
        }
        fn write(ptr: *anyopaque, reg: u16, size: u8, value: u32) void {
            _ = ptr;
            _ = reg;
            _ = size;
            _ = value;
        }
    };
    var fake = Fake{};
    var host = Host{};
    try host.addFunction(.{ .ptr = &fake, .dev = 1, .func = 0, .read = Fake.read, .write = Fake.write });
    const dev = host.mmioDevice();

    // Device 1, function 0, register 0: vendor/device id.
    var buf = [_]u8{0} ** 4;
    dev.read_fn(dev.ptr, 1 << 15, &buf);
    try std.testing.expectEqual(@as(u32, 0x1042_1AF4), std.mem.readInt(u32, &buf, .little));

    // Absent device 2: all-ones.
    dev.read_fn(dev.ptr, 2 << 15, &buf);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), std.mem.readInt(u32, &buf, .little));

    // A non-zero register offset is decoded and passed through.
    dev.read_fn(dev.ptr, (1 << 15) | 0x34, &buf);
    try std.testing.expectEqual(@as(u16, 0x34), fake.last_reg);
}
