//! PVH direct boot. Loads a PVH-capable ELF kernel, places the ACPI tables and
//! an hvm_start_info block in guest RAM, and enters the kernel's 32-bit
//! protected-mode entry with EBX pointing at the start_info (the PVH ABI). No
//! UEFI, no real-mode trampoline. This is the edge fast-boot path.

const std = @import("std");
const memmap = @import("memmap.zig");
const elf = @import("elf.zig");
const acpi = @import("acpi.zig");
const vmm = @import("vm.zig");

pub const magic = 0x336ec578; // XEN_HVM_START_MAGIC_VALUE
pub const E820_RAM = 1;

// Low-memory layout for boot structures (all below the 1 MiB kernel load).
const gdt_addr = 0x1000;
const start_info_addr = 0x2000;
const acpi_addr = 0x7000;

fn w32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}
fn w64(b: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, b[off..][0..8], v, .little);
}

fn writeMemmapEntry(b: []u8, pos: *usize, addr: u64, size: u64, kind: u32) void {
    const p = pos.*;
    w64(b, p + 0, addr);
    w64(b, p + 8, size);
    w32(b, p + 16, kind);
    w32(b, p + 20, 0); // reserved
    pos.* = p + 24;
}

pub const StartInfo = struct { addr: u64, len: usize };

/// A boot module (e.g. an initramfs) already placed in guest RAM.
pub const Module = struct { addr: u64, size: u64 };

/// Build hvm_start_info (version 1) plus its memmap table, command line, and an
/// optional module list into `buf` at guest base `base`, describing `layout` RAM
/// and pointing the kernel at `rsdp`. Returns the start_info address and length.
pub fn buildStartInfo(
    buf: []u8,
    base: u64,
    layout: memmap.Layout,
    rsdp: u64,
    cmdline: []const u8,
    module: ?Module,
) StartInfo {
    @memset(buf, 0);
    var pos: usize = 0;

    const memmap_off = pos;
    var entries: u32 = 0;
    writeMemmapEntry(buf, &pos, layout.ram_low.base, layout.ram_low.size, E820_RAM);
    entries += 1;
    if (layout.ram_high) |hi| {
        writeMemmapEntry(buf, &pos, hi.base, hi.size, E820_RAM);
        entries += 1;
    }

    const cmdline_off = pos;
    @memcpy(buf[pos .. pos + cmdline.len], cmdline);
    pos += cmdline.len;
    buf[pos] = 0; // NUL terminator
    pos += 1;

    pos = std.mem.alignForward(usize, pos, 8);
    var nr_modules: u32 = 0;
    var modlist_addr: u64 = 0;
    if (module) |m| {
        const modlist_off = pos;
        w64(buf, modlist_off + 0, m.addr);
        w64(buf, modlist_off + 8, m.size);
        w64(buf, modlist_off + 16, 0); // cmdline_paddr
        w64(buf, modlist_off + 24, 0); // reserved
        pos += 32;
        nr_modules = 1;
        modlist_addr = base + modlist_off;
    }

    pos = std.mem.alignForward(usize, pos, 8);
    const si_off = pos;
    w32(buf, si_off + 0, magic);
    w32(buf, si_off + 4, 1); // version
    w32(buf, si_off + 8, 0); // flags
    w32(buf, si_off + 12, nr_modules);
    w64(buf, si_off + 16, modlist_addr);
    w64(buf, si_off + 24, base + cmdline_off);
    w64(buf, si_off + 32, rsdp);
    w64(buf, si_off + 40, base + memmap_off);
    w32(buf, si_off + 48, entries);
    w32(buf, si_off + 52, 0); // reserved
    pos = si_off + 56;

    return .{ .addr = base + si_off, .len = pos };
}

/// Load `kernel` and optional `initramfs`, place ACPI + start_info in guest RAM,
/// and set `vcpu` to enter the kernel via the PVH protocol.
pub fn boot(
    vm: *vmm.Vm,
    vcpu: *vmm.Vcpu,
    layout: memmap.Layout,
    kernel: []const u8,
    cmdline: []const u8,
    initramfs: ?[]const u8,
) !void {
    const Ctx = struct {
        vm: *vmm.Vm,
        pub fn write(self: @This(), gpa: u64, bytes: []const u8) !void {
            try self.vm.guestWrite(gpa, bytes);
        }
        pub fn zero(self: @This(), gpa: u64, len: usize) !void {
            try self.vm.guestZero(gpa, len);
        }
    };
    const entry = try elf.loadPvh(kernel, Ctx{ .vm = vm });

    // Boot GDT: null, flat 32-bit code (0x08), flat 32-bit data (0x10).
    var gdt: [24]u8 = undefined;
    w64(&gdt, 0, 0);
    w64(&gdt, 8, 0x00cf9b000000ffff);
    w64(&gdt, 16, 0x00cf93000000ffff);
    try vm.guestWrite(gdt_addr, &gdt);

    // ACPI tables at acpi_addr; RSDP handed to the kernel via start_info.
    var acpi_buf: [1024]u8 = undefined;
    const tables = acpi.build(&acpi_buf, acpi_addr, 1);
    try vm.guestWrite(acpi_addr, acpi_buf[0..tables.len]);

    // initramfs placed page-aligned near the top of low RAM, above the kernel.
    var module: ?Module = null;
    if (initramfs) |fs| {
        const top = layout.ram_low.base + layout.ram_low.size;
        const addr = (top - fs.len) & ~@as(u64, 0xfff);
        try vm.guestWrite(addr, fs);
        module = .{ .addr = addr, .size = fs.len };
    }

    // start_info block.
    var si_buf: [1024]u8 = undefined;
    const si = buildStartInfo(&si_buf, start_info_addr, layout, tables.rsdp_addr, cmdline, module);
    try vm.guestWrite(start_info_addr, si_buf[0..si.len]);

    try vcpu.setProtectedMode(entry, si.addr, gdt_addr);
}

test "start_info has the PVH magic and links its tables" {
    var buf: [512]u8 = undefined;
    const layout = memmap.Layout.compute(16 * memmap.mib);
    const si = buildStartInfo(&buf, 0x2000, layout, 0x7abc, "console=ttyS0", null);

    const o = si.addr - 0x2000;
    try std.testing.expectEqual(@as(u32, magic), std.mem.readInt(u32, buf[o..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, buf[o + 4 ..][0..4], .little)); // version
    try std.testing.expectEqual(@as(u64, 0x7abc), std.mem.readInt(u64, buf[o + 32 ..][0..8], .little)); // rsdp
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, buf[o + 48 ..][0..4], .little)); // one memmap entry
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[o + 12 ..][0..4], .little)); // no modules

    // The memmap entry describes low RAM as type RAM.
    const mm = std.mem.readInt(u64, buf[o + 40 ..][0..8], .little) - 0x2000;
    try std.testing.expectEqual(layout.ram_low.size, std.mem.readInt(u64, buf[mm + 8 ..][0..8], .little));
    try std.testing.expectEqual(@as(u32, E820_RAM), std.mem.readInt(u32, buf[mm + 16 ..][0..4], .little));
}

test "start_info carries an initramfs module" {
    var buf: [512]u8 = undefined;
    const layout = memmap.Layout.compute(16 * memmap.mib);
    const si = buildStartInfo(&buf, 0x2000, layout, 0x7abc, "x", .{ .addr = 0x123000, .size = 4096 });

    const o = si.addr - 0x2000;
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, buf[o + 12 ..][0..4], .little)); // nr_modules
    const ml = std.mem.readInt(u64, buf[o + 16 ..][0..8], .little) - 0x2000;
    try std.testing.expectEqual(@as(u64, 0x123000), std.mem.readInt(u64, buf[ml + 0 ..][0..8], .little));
    try std.testing.expectEqual(@as(u64, 4096), std.mem.readInt(u64, buf[ml + 8 ..][0..8], .little));
}
