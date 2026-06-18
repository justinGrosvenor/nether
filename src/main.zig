//! Nether Phase 0 binary: a thin wrapper over the embeddable core. Build a VM
//! with one RAM region and a serial device, load a comptime-assembled real-mode
//! blob that prints over COM1, and run until the guest halts.

const std = @import("std");
const nether = @import("root.zig");

const GUEST_RAM_SIZE = 16 * nether.memmap.mib; // ample for Phase 0
const CODE_LOAD_ADDR = 0x1000;

const message = "Nether lives. Phase 0: real-mode guest over COM1.\n";

/// Comptime-assemble a 16-bit real-mode program that prints `msg` byte by byte
/// to COM1, then triggers ACPI S5 soft-off. No loops or memory operands (just
/// `mov al, c; out dx, al` per character), so it is trivially correct. The S5
/// write drives the PM block end to end, so the run loop returns `.shutdown`.
fn buildBlob(comptime msg: []const u8) [3 + msg.len * 3 + 8]u8 {
    var buf: [3 + msg.len * 3 + 8]u8 = undefined;
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
    // ACPI S5 soft-off: write SLP_EN | (SLP_TYP=5) to PM1a_CNT (port 0x604).
    buf[i] = 0xBA; // mov dx, 0x604
    buf[i + 1] = 0x04;
    buf[i + 2] = 0x06;
    buf[i + 3] = 0xB8; // mov ax, 0x3400  (SLP_EN=0x2000 | 5<<10)
    buf[i + 4] = 0x00;
    buf[i + 5] = 0x34;
    buf[i + 6] = 0xEF; // out dx, ax
    buf[i + 7] = 0xF4; // hlt (fallback if shutdown does not fire)
    return buf;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var vm = try nether.Vm.init(allocator);
    defer vm.deinit();

    // The memory map is the single source of truth; register every RAM region
    // it produces. Low RAM holds the boot blob.
    const layout = nether.memmap.Layout.compute(GUEST_RAM_SIZE);
    const low = try vm.addMemory(0, layout.ram_low.base, layout.ram_low.size);
    if (layout.ram_high) |hi| _ = try vm.addMemory(1, hi.base, hi.size);

    const blob = comptime buildBlob(message);
    @memcpy(low[CODE_LOAD_ADDR .. CODE_LOAD_ADDR + blob.len], blob[0..]);

    // Firmware floor: serial, RTC, the ACPI PM block, and the 0xCF9 reset port.
    var power = nether.Power{};
    var serial = nether.Serial{};
    var rtc = nether.Rtc{};
    var pm = nether.Pm{ .power = &power };
    var reset = nether.Reset{ .power = &power };

    var bus = nether.Bus{};
    try bus.addPio(serial.device());
    try bus.addPio(rtc.device());
    try bus.addPio(pm.device());
    try bus.addPio(reset.device());

    var vcpu = try vm.createVcpu(0);
    defer vcpu.deinit();
    try vcpu.setRealModeEntry(CODE_LOAD_ADDR);

    const reason = vcpu.run(&bus, &power) catch |err| {
        std.debug.print("[nether] vcpu stopped: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("\n[nether] guest {s}. Phase 0 complete.\n", .{@tagName(reason)});
}
