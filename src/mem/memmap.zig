//! Guest physical memory map: the single source of truth for where RAM and MMIO
//! live. KVM memory regions derive from it today; E820, MTRRs, and ACPI _CRS
//! will derive from the same place so the views never drift.
//!
//! Modern x86-64 layout, no legacy: low RAM runs from 0 up to the sub-4GiB PCI
//! hole; high RAM (if any) sits above 4GiB; the MMIO windows are fixed.

const std = @import("std");

pub const kib = 1 << 10;
pub const mib = 1 << 20;
pub const gib = 1 << 30;

pub const four_gib: u64 = 4 * gib;

/// Low RAM tops out at the start of the sub-4GiB MMIO hole.
pub const pci_hole_start: u64 = 0xC000_0000; // 3 GiB

// Fixed platform windows inside the hole.
pub const pci_mmio32_base: u64 = pci_hole_start; // 32-bit PCI MMIO window
pub const ecam_base: u64 = 0xE000_0000; // PCIe ECAM
pub const ecam_size: u64 = 256 * mib; // 256 buses
pub const ioapic_base: u64 = 0xFEC0_0000;
pub const lapic_base: u64 = 0xFEE0_0000;
pub const apic_size: u64 = 4 * kib;

// 64-bit PCI MMIO window, placed above any plausible high RAM.
pub const pci_mmio64_base: u64 = 1 << 39; // 512 GiB
pub const pci_mmio64_size: u64 = 1 << 39;

pub const Region = struct { base: u64, size: u64 };

pub const ReservedRange = struct { name: []const u8, base: u64, size: u64 };

/// MMIO ranges the guest must not treat as RAM. ACPI `_CRS` and the E820
/// reserved entries will be generated from this list.
pub const reserved = [_]ReservedRange{
    .{ .name = "pci-mmio32", .base = pci_mmio32_base, .size = ecam_base - pci_mmio32_base },
    .{ .name = "ecam", .base = ecam_base, .size = ecam_size },
    .{ .name = "ioapic", .base = ioapic_base, .size = apic_size },
    .{ .name = "lapic", .base = lapic_base, .size = apic_size },
    .{ .name = "pci-mmio64", .base = pci_mmio64_base, .size = pci_mmio64_size },
};

pub const Layout = struct {
    ram_low: Region,
    ram_high: ?Region,
    total_ram: u64,

    /// Split `total_ram` around the sub-4GiB PCI hole.
    pub fn compute(total_ram: u64) Layout {
        if (total_ram <= pci_hole_start) {
            return .{
                .ram_low = .{ .base = 0, .size = total_ram },
                .ram_high = null,
                .total_ram = total_ram,
            };
        }
        return .{
            .ram_low = .{ .base = 0, .size = pci_hole_start },
            .ram_high = .{ .base = four_gib, .size = total_ram - pci_hole_start },
            .total_ram = total_ram,
        };
    }
};

test "small RAM stays in one low region below the hole" {
    const l = Layout.compute(16 * mib);
    try std.testing.expectEqual(@as(u64, 0), l.ram_low.base);
    try std.testing.expectEqual(@as(u64, 16 * mib), l.ram_low.size);
    try std.testing.expect(l.ram_high == null);
}

test "large RAM splits around the PCI hole" {
    const l = Layout.compute(8 * gib);
    try std.testing.expectEqual(pci_hole_start, l.ram_low.size);
    try std.testing.expect(l.ram_high != null);
    try std.testing.expectEqual(four_gib, l.ram_high.?.base);
    try std.testing.expectEqual(8 * gib - pci_hole_start, l.ram_high.?.size);
}

test "no reserved MMIO range overlaps RAM" {
    const l = Layout.compute(8 * gib);
    const high_end = l.ram_high.?.base + l.ram_high.?.size;
    for (reserved) |r| {
        // Reserved ranges live at or above the hole, never inside low RAM.
        try std.testing.expect(r.base >= pci_hole_start);
        // And never inside high RAM.
        const overlaps_high = r.base < high_end and r.base + r.size > l.ram_high.?.base;
        try std.testing.expect(!overlaps_high);
    }
}
