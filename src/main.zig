//! Nether Phase 0 binary: a thin wrapper over the embeddable core. Build a VM
//! with one RAM region and a serial device, load a comptime-assembled real-mode
//! blob that prints over COM1, and run until the guest halts.

const std = @import("std");
const nether = @import("root.zig");

const GUEST_RAM_SIZE = 0x20000; // 128 KiB, ample for Phase 0
const CODE_LOAD_ADDR = 0x1000;

const message = "Nether lives. Phase 0: real-mode guest over COM1.\n";

/// Comptime-assemble a 16-bit real-mode program that prints `msg` byte by byte
/// to COM1, then halts. No loops or memory operands (just `mov al, c; out dx,
/// al` per character), so it is trivially correct.
fn buildBlob(comptime msg: []const u8) [3 + msg.len * 3 + 1]u8 {
    var buf: [3 + msg.len * 3 + 1]u8 = undefined;
    buf[0] = 0xBA; // mov dx, 0x3f8
    buf[1] = 0xF8;
    buf[2] = 0x03;
    var i: usize = 3;
    for (msg) |c| {
        buf[i] = 0xB0; // mov al, imm8
        buf[i + 1] = c;
        buf[i + 2] = 0xEE; // out dx, al
        i += 3;
    }
    buf[i] = 0xF4; // hlt
    return buf;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var vm = try nether.Vm.init(allocator);
    defer vm.deinit();

    const mem = try vm.addMemory(0, 0, GUEST_RAM_SIZE);
    const blob = comptime buildBlob(message);
    @memcpy(mem[CODE_LOAD_ADDR .. CODE_LOAD_ADDR + blob.len], blob[0..]);

    var serial = nether.Serial{};
    var bus = nether.Bus{};
    try bus.add(serial.device());

    var vcpu = try vm.createVcpu(0);
    defer vcpu.deinit();
    try vcpu.setRealModeEntry(CODE_LOAD_ADDR);

    const reason = vcpu.run(&bus) catch |err| {
        std.debug.print("[nether] vcpu stopped: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("\n[nether] guest {s}. Phase 0 complete.\n", .{@tagName(reason)});
}
