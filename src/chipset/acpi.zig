//! Minimal static ACPI tables, fixed-placement model: tables are written into a
//! guest RAM buffer at a known base with real cross-pointers and checksums. This
//! is the form a PVH/direct boot consumes (the kernel is handed the RSDP
//! address). The OVMF path additionally needs these wrapped in the ACPI
//! linker/loader and served over fw_cfg; that wrapping is a later step.
//!
//! Set emitted: RSDP, XSDT, FADT (+ FACS), MADT, MCFG, and a minimal DSDT whose
//! only content is the _S5 package, matching pm.zig's S5 soft-off.

const std = @import("std");
const memmap = @import("../mem/memmap.zig");
const pm = @import("../chipset/pm.zig");

const oem_id = [6]u8{ 'N', 'E', 'T', 'H', 'E', 'R' };
const oem_table = [8]u8{ 'N', 'E', 'T', 'H', 'E', 'R', '0', ' ' };
const creator_id = [4]u8{ 'N', 'T', 'H', 'R' };

/// Byte that makes the region sum to zero (mod 256).
fn checksum(b: []const u8) u8 {
    var sum: u8 = 0;
    for (b) |x| sum +%= x;
    return 0 -% sum;
}

fn w16(b: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, b[off..][0..2], v, .little);
}
fn w32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}
fn w64(b: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, b[off..][0..8], v, .little);
}

/// Write the common 36-byte System Description Table header. Length and
/// checksum are filled by finalizeSdt once the body is written.
fn writeHeader(b: []u8, sig: []const u8, revision: u8) void {
    @memcpy(b[0..4], sig);
    b[8] = revision;
    @memcpy(b[10..16], &oem_id);
    @memcpy(b[16..24], &oem_table);
    w32(b, 24, 1); // oem_revision
    @memcpy(b[28..32], &creator_id);
    w32(b, 32, 1); // creator_revision
}

fn finalizeSdt(b: []u8, len: usize) void {
    w32(b, 4, @intCast(len));
    b[9] = 0;
    b[9] = checksum(b[0..len]);
}

/// Generic Address Structure (12 bytes).
fn writeGas(b: []u8, off: usize, space: u8, width: u8, access: u8, addr: u64) void {
    b[off] = space; // 1 = SystemIO
    b[off + 1] = width;
    b[off + 2] = 0; // bit offset
    b[off + 3] = access;
    w64(b, off + 4, addr);
}

// Full DSDT (header + AML) compiled from dsdt.asl by iasl: S5 plus a PCIe host
// bridge with a _CRS bus range and MMIO window. Embedded verbatim; it carries
// its own valid header and checksum.
const dsdt_table = @embedFile("dsdt.aml");

fn writeFacs(b: []u8) usize {
    @memcpy(b[0..4], "FACS");
    w32(b, 4, 64); // length
    b[32] = 2; // version
    return 64; // FACS has no checksum
}

fn writeDsdt(b: []u8) usize {
    @memcpy(b[0..dsdt_table.len], dsdt_table);
    return dsdt_table.len;
}

fn writeFadt(b: []u8, dsdt_addr: u64, facs_addr: u64) usize {
    const len = 276;
    writeHeader(b, "FACP", 6);
    w32(b, 36, @truncate(facs_addr)); // FIRMWARE_CTRL
    w32(b, 40, @truncate(dsdt_addr)); // DSDT
    w16(b, 46, 9); // SCI_INT
    w32(b, 56, pm.Pm.base); // PM1a_EVT_BLK
    w32(b, 64, pm.Pm.base + 4); // PM1a_CNT_BLK
    w32(b, 76, pm.Pm.base + 8); // PM_TMR_BLK
    b[88] = 4; // PM1_EVT_LEN
    b[89] = 2; // PM1_CNT_LEN
    b[91] = 4; // PM_TMR_LEN
    b[108] = 0x32; // CENTURY (RTC century register index)
    w32(b, 112, 1 << 10); // Flags: RESET_REG_SUP
    writeGas(b, 116, 1, 8, 1, 0xCF9); // RESET_REG = SystemIO 0xCF9
    b[128] = 0x06; // RESET_VALUE
    b[131] = 0; // FADT minor version
    w64(b, 132, facs_addr); // X_FIRMWARE_CTRL
    w64(b, 140, dsdt_addr); // X_DSDT
    writeGas(b, 148, 1, 32, 3, pm.Pm.base); // X_PM1a_EVT_BLK
    writeGas(b, 172, 1, 16, 2, pm.Pm.base + 4); // X_PM1a_CNT_BLK
    writeGas(b, 208, 1, 32, 3, pm.Pm.base + 8); // X_PM_TMR_BLK
    finalizeSdt(b, len);
    return len;
}

fn writeMadt(b: []u8, num_cpus: u32) usize {
    writeHeader(b, "APIC", 5);
    w32(b, 36, @truncate(memmap.lapic_base)); // Local APIC address
    w32(b, 40, 1); // Flags: PCAT_COMPAT (8259 present)
    var off: usize = 44;
    var cpu: u32 = 0;
    while (cpu < num_cpus) : (cpu += 1) {
        b[off] = 0; // type: Processor Local APIC
        b[off + 1] = 8; // length
        b[off + 2] = @intCast(cpu); // ACPI processor id
        b[off + 3] = @intCast(cpu); // APIC id
        w32(b, off + 4, 1); // flags: enabled
        off += 8;
    }
    b[off] = 1; // type: IOAPIC
    b[off + 1] = 12; // length
    b[off + 2] = 0; // ioapic id
    b[off + 3] = 0; // reserved
    w32(b, off + 4, @truncate(memmap.ioapic_base));
    w32(b, off + 8, 0); // GSI base
    off += 12;
    finalizeSdt(b, off);
    return off;
}

fn writeMcfg(b: []u8) usize {
    writeHeader(b, "MCFG", 1);
    // 8 reserved bytes at offset 36 are already zero.
    w64(b, 44, memmap.ecam_base); // base address
    w16(b, 52, 0); // PCI segment group
    b[54] = 0; // start bus
    b[55] = 255; // end bus
    w32(b, 56, 0); // reserved
    const len = 60;
    finalizeSdt(b, len);
    return len;
}

fn writeXsdt(b: []u8, ptrs: []const u64) usize {
    writeHeader(b, "XSDT", 1);
    var off: usize = 36;
    for (ptrs) |p| {
        w64(b, off, p);
        off += 8;
    }
    finalizeSdt(b, off);
    return off;
}

fn writeRsdp(b: []u8, xsdt_addr: u64) usize {
    @memcpy(b[0..8], "RSD PTR ");
    @memcpy(b[9..15], &oem_id);
    b[15] = 2; // revision (ACPI 2.0+)
    w32(b, 16, 0); // RSDT address (unused, we use XSDT)
    w32(b, 20, 36); // length
    w64(b, 24, xsdt_addr);
    b[8] = 0;
    b[8] = checksum(b[0..20]); // first-20 checksum
    b[32] = 0;
    b[32] = checksum(b[0..36]); // extended checksum
    return 36;
}

pub const Tables = struct {
    rsdp_addr: u64,
    len: usize,
};

/// Build the full table set into `buf` (must be zeroed-tolerant; we zero it) at
/// guest physical `base`. Returns the RSDP address and total bytes used.
pub fn build(buf: []u8, base: u64, num_cpus: u32) Tables {
    @memset(buf, 0);
    var pos: usize = 0;

    const facs_addr = base + pos;
    pos += writeFacs(buf[pos..]);

    const dsdt_addr = base + pos;
    pos += writeDsdt(buf[pos..]);

    const fadt_addr = base + pos;
    pos += writeFadt(buf[pos..], dsdt_addr, facs_addr);

    const madt_addr = base + pos;
    pos += writeMadt(buf[pos..], num_cpus);

    const mcfg_addr = base + pos;
    pos += writeMcfg(buf[pos..]);

    const xsdt_addr = base + pos;
    pos += writeXsdt(buf[pos..], &.{ fadt_addr, madt_addr, mcfg_addr });

    const rsdp_addr = base + pos;
    pos += writeRsdp(buf[pos..], xsdt_addr);

    return .{ .rsdp_addr = rsdp_addr, .len = pos };
}

fn sumZero(b: []const u8) bool {
    var sum: u8 = 0;
    for (b) |x| sum +%= x;
    return sum == 0;
}

test "table set links and checksums" {
    var buf: [1024]u8 = undefined;
    const base: u64 = 0x9000;
    const t = build(&buf, base, 2);

    // RSDP
    const rsdp = buf[t.rsdp_addr - base ..][0..36];
    try std.testing.expectEqualSlices(u8, "RSD PTR ", rsdp[0..8]);
    try std.testing.expect(sumZero(rsdp[0..20]));
    try std.testing.expect(sumZero(rsdp[0..36]));

    // XSDT
    const xsdt_addr = std.mem.readInt(u64, rsdp[24..32], .little);
    const xsdt = buf[xsdt_addr - base ..];
    try std.testing.expectEqualSlices(u8, "XSDT", xsdt[0..4]);
    const xsdt_len = std.mem.readInt(u32, xsdt[4..8], .little);
    try std.testing.expect(sumZero(xsdt[0..xsdt_len]));
    try std.testing.expectEqual(@as(u32, 36 + 3 * 8), xsdt_len); // three table pointers

    // Each pointed-to table has a good signature and checksum.
    var i: usize = 36;
    var saw_fadt = false;
    while (i < xsdt_len) : (i += 8) {
        const addr = std.mem.readInt(u64, xsdt[i..][0..8], .little);
        const tbl = buf[addr - base ..];
        const len = std.mem.readInt(u32, tbl[4..8], .little);
        try std.testing.expect(sumZero(tbl[0..len]));
        if (std.mem.eql(u8, tbl[0..4], "FACP")) {
            saw_fadt = true;
            // FADT PM1a_CNT_BLK points at our PM block.
            try std.testing.expectEqual(@as(u32, pm.Pm.base + 4), std.mem.readInt(u32, tbl[64..68], .little));
            // FADT DSDT pointer has a valid DSDT.
            const dsdt_addr = std.mem.readInt(u32, tbl[40..44], .little);
            const dsdt = buf[dsdt_addr - base ..];
            try std.testing.expectEqualSlices(u8, "DSDT", dsdt[0..4]);
            const dlen = std.mem.readInt(u32, dsdt[4..8], .little);
            try std.testing.expect(sumZero(dsdt[0..dlen]));
        }
    }
    try std.testing.expect(saw_fadt);
}

test "madt scales with cpu count" {
    var a: [1024]u8 = undefined;
    var b: [1024]u8 = undefined;
    const one = build(&a, 0x9000, 1);
    const four = build(&b, 0x9000, 4);
    // More CPUs means more Local APIC entries, so a longer image.
    try std.testing.expect(four.len > one.len);
    try std.testing.expectEqual(@as(usize, (4 - 1) * 8), four.len - one.len);
}
