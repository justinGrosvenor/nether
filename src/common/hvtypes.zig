//! Hypervisor-backend-agnostic types shared by the KVM and HVF backends and by
//! the Vm/Vcpu wrapper in vm.zig. This is a leaf file (it imports no backend),
//! so the backends and the selector can all depend on it without an import
//! cycle. See backend.zig for the comptime KVM/HVF selection.

const std = @import("std");

/// Why a vCPU run loop returned. Backend-independent.
pub const StopReason = enum { halted, shutdown, reset };

/// The common error set every backend's Vm/Vcpu may surface. Backends union
/// their own (e.g. kvm.Error) on top via inferred error sets.
pub const Error = error{
    BadApiVersion,
    SyscallFailed,
    TooManyRegions,
    NotMapped,
    Unimplemented,
};

/// Little-endian assemble up to 4 bytes into a value (PIO/MMIO data marshalling).
/// `i < 4` enforces the "up to 4 bytes" contract: the value is a u32, so a wider
/// access (an oversized guest PIO/MMIO) must not drive the `i*8` shift past the u5
/// shift width (which would panic). Bytes beyond the low 4 are ignored.
pub fn readValue(bytes: []const u8) u32 {
    var v: u32 = 0;
    for (bytes, 0..) |b, i| {
        if (i < 4) v |= @as(u32, b) << @intCast(i * 8);
    }
    return v;
}

/// Little-endian scatter a value across the given bytes (bytes past the u32's low 4
/// are zeroed; same shift-width guard as readValue).
pub fn writeValue(bytes: []u8, value: u32) void {
    for (bytes, 0..) |*b, i| b.* = if (i < 4) @truncate(value >> @intCast(i * 8)) else 0;
}

test "value round-trips little-endian" {
    var buf = [_]u8{ 0, 0, 0, 0 };
    writeValue(&buf, 0x11223344);
    try std.testing.expectEqual(@as(u8, 0x44), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x11), buf[3]);
    try std.testing.expectEqual(@as(u32, 0x11223344), readValue(&buf));
}
