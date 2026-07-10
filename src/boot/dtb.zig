//! Device Tree Blob (DTB / flattened device tree) generator: the arm64 analog of
//! acpi.zig. aarch64 Linux is handed a pointer to one of these in x0 at boot; it
//! describes RAM, the CPU(s), PSCI, the GIC, the timer, and the PL011 UART. The
//! `Builder` writes the FDT wire format (big-endian, version 17); `buildVirt`
//! assembles the "virt" platform tree from the memmap_arm layout.
//!
//! The GIC/timer details mirror the de-facto QEMU "virt" board but are
//! provisional until the GIC is wired against Apple's hv_gic (the boot chunk);
//! the FDT *encoding* is what these tests pin down.

const std = @import("std");
const arm = @import("../mem/memmap_arm.zig");

const FDT_MAGIC: u32 = 0xd00d_feed;
const FDT_BEGIN_NODE: u32 = 1;
const FDT_END_NODE: u32 = 2;
const FDT_PROP: u32 = 3;
const FDT_END: u32 = 9;
const FDT_VERSION: u32 = 17;
const FDT_LAST_COMP: u32 = 16;

const HEADER_SIZE = 40;
const RSVMAP_SIZE = 16; // one terminating (address=0, size=0) entry

pub const Builder = struct {
    sbuf: []u8, // structure block accumulator
    slen: usize = 0,
    strbuf: []u8, // strings block accumulator
    strlen: usize = 0,

    pub fn init(struct_scratch: []u8, strings_scratch: []u8) Builder {
        return .{ .sbuf = struct_scratch, .strbuf = strings_scratch };
    }

    pub fn beginNode(self: *Builder, name: []const u8) void {
        self.put32(FDT_BEGIN_NODE);
        @memcpy(self.sbuf[self.slen..][0..name.len], name);
        self.slen += name.len;
        self.sbuf[self.slen] = 0; // name NUL
        self.slen += 1;
        self.padTo4();
    }

    pub fn endNode(self: *Builder) void {
        self.put32(FDT_END_NODE);
    }

    pub fn propEmpty(self: *Builder, name: []const u8) void {
        self.header(name, 0);
    }

    pub fn propU32(self: *Builder, name: []const u8, v: u32) void {
        self.header(name, 4);
        self.put32(v);
    }

    pub fn propU64(self: *Builder, name: []const u8, v: u64) void {
        self.header(name, 8);
        self.put32(@truncate(v >> 32));
        self.put32(@truncate(v));
    }

    pub fn propCells(self: *Builder, name: []const u8, cells: []const u32) void {
        self.header(name, cells.len * 4);
        for (cells) |c| self.put32(c);
    }

    pub fn propString(self: *Builder, name: []const u8, s: []const u8) void {
        self.header(name, s.len + 1);
        @memcpy(self.sbuf[self.slen..][0..s.len], s);
        self.slen += s.len;
        self.sbuf[self.slen] = 0;
        self.slen += 1;
        self.padTo4();
    }

    /// A raw byte-array property (no NUL terminator), e.g. /chosen rng-seed.
    pub fn propBytes(self: *Builder, name: []const u8, bytes: []const u8) void {
        self.header(name, bytes.len);
        @memcpy(self.sbuf[self.slen..][0..bytes.len], bytes);
        self.slen += bytes.len;
        self.padTo4();
    }

    /// A <stringlist>: several NUL-terminated strings concatenated (e.g.
    /// compatible = "arm,pl011", "arm,primecell").
    pub fn propStrings(self: *Builder, name: []const u8, parts: []const []const u8) void {
        var total: usize = 0;
        for (parts) |p| total += p.len + 1;
        self.header(name, total);
        for (parts) |p| {
            @memcpy(self.sbuf[self.slen..][0..p.len], p);
            self.slen += p.len;
            self.sbuf[self.slen] = 0;
            self.slen += 1;
        }
        self.padTo4();
    }

    /// Assemble the full DTB (header, reservation map, structure, strings) into
    /// `out` and return its total size.
    pub fn finish(self: *Builder, out: []u8) usize {
        self.put32(FDT_END);

        const struct_off = HEADER_SIZE + RSVMAP_SIZE;
        const strings_off = struct_off + self.slen;
        const total = strings_off + self.strlen;

        // fdt_header (all big-endian).
        const h = [_]u32{
            FDT_MAGIC,
            @intCast(total),
            @intCast(struct_off),
            @intCast(strings_off),
            HEADER_SIZE, // off_mem_rsvmap
            FDT_VERSION,
            FDT_LAST_COMP,
            0, // boot_cpuid_phys
            @intCast(self.strlen),
            @intCast(self.slen),
        };
        for (h, 0..) |v, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], v, .big);

        @memset(out[HEADER_SIZE .. HEADER_SIZE + RSVMAP_SIZE], 0); // empty rsvmap
        @memcpy(out[struct_off..][0..self.slen], self.sbuf[0..self.slen]);
        @memcpy(out[strings_off..][0..self.strlen], self.strbuf[0..self.strlen]);
        return total;
    }

    // --- internals ---------------------------------------------------------

    fn header(self: *Builder, name: []const u8, vlen: usize) void {
        self.put32(FDT_PROP);
        self.put32(@intCast(vlen));
        self.put32(@intCast(self.internString(name)));
    }

    fn put32(self: *Builder, v: u32) void {
        std.mem.writeInt(u32, self.sbuf[self.slen..][0..4], v, .big);
        self.slen += 4;
    }

    fn padTo4(self: *Builder) void {
        while (self.slen % 4 != 0) : (self.slen += 1) self.sbuf[self.slen] = 0;
    }

    /// Intern a property name into the strings block (deduplicated), returning
    /// its offset for the FDT_PROP nameoff field.
    fn internString(self: *Builder, name: []const u8) usize {
        var i: usize = 0;
        while (i < self.strlen) {
            const end = std.mem.indexOfScalarPos(u8, self.strbuf[0..self.strlen], i, 0).?;
            if (std.mem.eql(u8, self.strbuf[i..end], name)) return i;
            i = end + 1;
        }
        const off = self.strlen;
        @memcpy(self.strbuf[off..][0..name.len], name);
        self.strbuf[off + name.len] = 0;
        self.strlen += name.len + 1;
        return off;
    }
};

fn hi(x: u64) u32 {
    return @truncate(x >> 32);
}
fn lo(x: u64) u32 {
    return @truncate(x);
}

/// Parameters for the "virt" device tree. GIC region sizes come from the
/// framework GIC at runtime; the initrd range is set when an initramfs is loaded.
/// A virtio-mmio device to describe: its register window and SPI number (the
/// GIC interrupt id relative to the SPI base, i.e. INTID = 32 + spi).
pub const VirtioDev = struct { addr: u64, spi: u32 };

/// A generic-ECAM PCIe host bridge: the config window plus a 32-bit and a 64-bit
/// MMIO window for BARs (identity-mapped PCI<->CPU).
pub const PcieConfig = struct {
    ecam_base: u64,
    ecam_size: u64,
    io_base: u64,
    io_size: u64,
    mmio_base: u64,
    mmio_size: u64,
    mmio64_base: u64,
    mmio64_size: u64,
};

/// A GICv2m MSI frame: a doorbell region plus a contiguous range of GIC SPIs the
/// frame translates message writes into. Described as a child of the GIC node so
/// the PCIe host bridge can use MSI/MSI-X instead of legacy INTx.
pub const MsiConfig = struct {
    doorbell_base: u64,
    doorbell_size: u64,
    spi_base: u32,
    spi_count: u32,
};

pub const VirtConfig = struct {
    cmdline: []const u8,
    mem_base: u64,
    mem_size: u64,
    gicd_size: u64 = arm.gicd_size,
    gicr_base: u64 = arm.gicr_base,
    gicr_size: u64 = arm.gicr_size,
    initrd_start: u64 = 0,
    initrd_end: u64 = 0,
    num_cpus: u32 = 1,
    virtio: []const VirtioDev = &.{},
    pcie: ?PcieConfig = null,
    msi: ?MsiConfig = null,
    // /chosen rng-seed: host-provided entropy the kernel mixes into (and, with
    // CONFIG_RANDOM_TRUST_BOOTLOADER, credits to) its crng at boot. Without it a quiet
    // microVM takes ~10s of jitter accumulation before getrandom() unblocks - which
    // stalls the first python (hash-seed) in every fresh boot AND in every fork whose
    // base was baked before the crng self-initialized. Empty = omit the property.
    rng_seed: []const u8 = &.{},
    // vmgenid GUID guest-physical address (0 = omit the node). The caller places it in a
    // page it reserved out of `mem_size` (the top page of RAM), so the region is not
    // System RAM and the guest driver can ioremap it. See memmap_arm.vmgenid_page.
    vmgenid_addr: u64 = 0,
};

/// Build the "virt" device tree into `out` and return its size. Uses two
/// phandles: 1 = GIC (interrupt-parent), 2 = the PL011 reference clock.
pub fn buildVirt(out: []u8, cfg: VirtConfig) usize {
    var sbuf: [4096]u8 = undefined;
    var strbuf: [1024]u8 = undefined;
    var b = Builder.init(&sbuf, &strbuf);

    const GIC_PHANDLE = 1;
    const CLK_PHANDLE = 2;
    const V2M_PHANDLE = 3;

    b.beginNode(""); // root
    b.propU32("#address-cells", 2);
    b.propU32("#size-cells", 2);
    b.propString("compatible", "linux,dummy-virt");
    b.propString("model", "nether-virt");
    b.propU32("interrupt-parent", GIC_PHANDLE);

    b.beginNode("psci");
    b.propStrings("compatible", &.{ "arm,psci-1.0", "arm,psci-0.2" });
    b.propString("method", "hvc");
    b.endNode();

    b.beginNode("chosen");
    b.propString("bootargs", cfg.cmdline);
    b.propString("stdout-path", "/pl011@9000000");
    if (cfg.rng_seed.len > 0) b.propBytes("rng-seed", cfg.rng_seed);
    // Force the kernel out of PCI_PROBE_ONLY so it *assigns* (not just claims)
    // BARs. With a direct kernel boot there is no firmware to assign PCI
    // resources; without this the generic host bridge leaves BARs unassigned and
    // virtio-pci can't enable the device.
    b.propU32("linux,pci-probe-only", 0);
    if (cfg.initrd_end > cfg.initrd_start) {
        b.propU64("linux,initrd-start", cfg.initrd_start);
        b.propU64("linux,initrd-end", cfg.initrd_end);
    }
    b.endNode();

    b.beginNode("apb-pclk"); // fixed reference clock for the PL011
    b.propString("compatible", "fixed-clock");
    b.propU32("#clock-cells", 0);
    b.propU32("clock-frequency", arm.apb_clock_hz);
    b.propString("clock-output-names", "uartclk");
    b.propU32("phandle", CLK_PHANDLE);
    b.endNode();

    b.beginNode("timer");
    b.propString("compatible", "arm,armv8-timer");
    // Four generic-timer PPIs (secure, non-secure, virtual, hyp), level, CPU0.
    b.propCells("interrupts", &.{ 1, 13, 0x104, 1, 14, 0x104, 1, 11, 0x104, 1, 10, 0x104 });
    b.propEmpty("always-on");
    b.endNode();

    b.beginNode("cpus");
    b.propU32("#address-cells", 1);
    b.propU32("#size-cells", 0);
    // One cpu node per vCPU. reg = the core's MPIDR affinity (Aff0 = id for the
    // small core counts we run); enable-method = psci so the kernel uses PSCI
    // CPU_ON to bring secondaries online.
    var cpu: u32 = 0;
    while (cpu < cfg.num_cpus) : (cpu += 1) {
        var cpuname: [16]u8 = undefined;
        const cn = std.fmt.bufPrint(&cpuname, "cpu@{x}", .{cpu}) catch unreachable;
        b.beginNode(cn);
        b.propString("device_type", "cpu");
        b.propString("compatible", "arm,armv8");
        b.propU32("reg", cpu);
        b.propString("enable-method", "psci");
        b.endNode();
    }
    b.endNode();

    b.beginNode("intc@8000000"); // GICv3
    b.propString("compatible", "arm,gic-v3");
    b.propEmpty("interrupt-controller");
    b.propU32("#interrupt-cells", 3);
    // #address-cells/#size-cells/ranges so a PCIe interrupt-map referencing this
    // controller as its parent parses correctly (the parent's #address-cells
    // sizes the address part of each map entry's parent specifier).
    b.propU32("#address-cells", 2);
    b.propU32("#size-cells", 2);
    b.propEmpty("ranges");
    b.propCells("reg", &.{
        hi(arm.gicd_base), lo(arm.gicd_base), hi(cfg.gicd_size), lo(cfg.gicd_size),
        hi(cfg.gicr_base), lo(cfg.gicr_base), hi(cfg.gicr_size), lo(cfg.gicr_size),
    });
    b.propU32("phandle", GIC_PHANDLE);
    if (cfg.msi) |m| {
        // GICv2m MSI frame (child of the GIC). The frame translates a doorbell
        // write into one of [spi_base, spi_base+spi_count) SPIs; advertising the
        // base/count here makes the guest skip reading MSI_TYPER from the frame
        // (which lives in the framework-owned MSI region).
        var v2mname: [40]u8 = undefined;
        const vn = std.fmt.bufPrint(&v2mname, "v2m@{x}", .{m.doorbell_base}) catch unreachable;
        b.beginNode(vn);
        b.propString("compatible", "arm,gic-v2m-frame");
        b.propEmpty("msi-controller");
        b.propCells("reg", &.{ hi(m.doorbell_base), lo(m.doorbell_base), hi(m.doorbell_size), lo(m.doorbell_size) });
        b.propU32("arm,msi-base-spi", m.spi_base);
        b.propU32("arm,msi-num-spis", m.spi_count);
        b.propU32("phandle", V2M_PHANDLE);
        b.endNode();
    }
    b.endNode();

    b.beginNode("memory@40000000");
    b.propString("device_type", "memory");
    b.propCells("reg", &.{ hi(cfg.mem_base), lo(cfg.mem_base), hi(cfg.mem_size), lo(cfg.mem_size) });
    b.endNode();

    // vmgenid: the guest's microsoft,vmgenid driver ioremaps this 16-byte GUID region (a
    // page the memory node excludes, so it is not System RAM) and reseeds the crng when the
    // host changes the GUID and pulses the SPI on restore. Emitted only when the caller
    // reserved the page (vmgenid_addr != 0). Edge-rising interrupt: the pulse is a one-shot
    // generation-change notification.
    if (cfg.vmgenid_addr != 0) {
        var vgname: [40]u8 = undefined;
        const vgn = std.fmt.bufPrint(&vgname, "vmgenid@{x}", .{cfg.vmgenid_addr}) catch unreachable;
        b.beginNode(vgn);
        b.propString("compatible", "microsoft,vmgenid");
        b.propCells("reg", &.{ hi(cfg.vmgenid_addr), lo(cfg.vmgenid_addr), hi(arm.vmgenid_page), lo(arm.vmgenid_page) });
        b.propCells("interrupts", &.{ 0, arm.vmgenid_spi, 0x01 }); // SPI, id, edge-rising
        b.endNode();
    }

    b.beginNode("pl011@9000000");
    b.propStrings("compatible", &.{ "arm,pl011", "arm,primecell" });
    b.propCells("reg", &.{ hi(arm.uart_base), lo(arm.uart_base), hi(arm.uart_size), lo(arm.uart_size) });
    b.propCells("interrupts", &.{ 0, arm.uart_spi, 0x04 }); // SPI, id, level-high
    b.propCells("clocks", &.{ CLK_PHANDLE, CLK_PHANDLE });
    b.propStrings("clock-names", &.{ "uartclk", "apb_pclk" });
    b.endNode();

    // PL031 RTC: the guest's wall clock. rtc-pl031 binds via the AMBA id and, with
    // rtc-hctosys, sets CLOCK_REALTIME from it at boot (else the guest starts at 1970).
    b.beginNode("pl031@9010000");
    b.propStrings("compatible", &.{ "arm,pl031", "arm,primecell" });
    b.propCells("reg", &.{ hi(arm.rtc_base), lo(arm.rtc_base), hi(arm.rtc_size), lo(arm.rtc_size) });
    b.propCells("interrupts", &.{ 0, arm.rtc_spi, 0x04 }); // SPI, id, level-high (alarm; never asserted)
    b.propCells("clocks", &.{CLK_PHANDLE});
    b.propStrings("clock-names", &.{"apb_pclk"});
    b.endNode();

    for (cfg.virtio) |vd| {
        var namebuf: [40]u8 = undefined;
        const name = std.fmt.bufPrint(&namebuf, "virtio_mmio@{x}", .{vd.addr}) catch unreachable;
        b.beginNode(name);
        b.propString("compatible", "virtio,mmio");
        b.propCells("reg", &.{ hi(vd.addr), lo(vd.addr), 0, @intCast(arm.virtio_mmio_stride) });
        b.propCells("interrupts", &.{ 0, vd.spi, 0x04 }); // SPI, number, level-high
        b.endNode();
    }

    if (cfg.pcie) |p| {
        var namebuf: [40]u8 = undefined;
        const name = std.fmt.bufPrint(&namebuf, "pcie@{x}", .{p.ecam_base}) catch unreachable;
        b.beginNode(name);
        b.propString("compatible", "pci-host-ecam-generic");
        b.propString("device_type", "pci");
        b.propU32("#address-cells", 3);
        b.propU32("#size-cells", 2);
        b.propU32("#interrupt-cells", 1);
        b.propU32("linux,pci-domain", 0);
        // MSI/MSI-X via the GICv2m frame (preferred over the INTx interrupt-map).
        if (cfg.msi != null) b.propU32("msi-parent", V2M_PHANDLE);
        b.propCells("reg", &.{ hi(p.ecam_base), lo(p.ecam_base), hi(p.ecam_size), lo(p.ecam_size) });
        // ECAM is 1 MiB = exactly one bus, so the bus-range must be a single bus
        // (pci_ecam_create sizes the config space as (bus_max+1) << 20).
        b.propCells("bus-range", &.{ 0, 0 });
        // Three windows, mirroring QEMU's virt board (all identity-mapped
        // PCI<->CPU): an I/O window (space 0x01000000), a 32-bit non-prefetchable
        // window (0x02000000; the host bridge requires one), and a 64-bit window
        // (0x03000000) where the virtio 64-bit BAR is assigned.
        b.propCells("ranges", &.{
            0x0100_0000, 0,                 0,               // I/O: PCI addr 0
            hi(p.io_base),                  lo(p.io_base), // CPU addr
            0,                              @intCast(p.io_size), // size
            0x0200_0000, hi(p.mmio_base),   lo(p.mmio_base), // 32-bit: PCI addr
            hi(p.mmio_base),                lo(p.mmio_base), // CPU addr
            hi(p.mmio_size),                lo(p.mmio_size), // size
            0x0300_0000, hi(p.mmio64_base), lo(p.mmio64_base), // 64-bit: PCI addr (matches QEMU virt)
            hi(p.mmio64_base),              lo(p.mmio64_base), // CPU addr
            hi(p.mmio64_size),              lo(p.mmio64_size), // size
        });
        b.propEmpty("dma-coherent");
        // INTx routing: map each (slot, pin) to a GIC SPI (the standard arm64
        // swizzle, base arm.pci_intx_spi). Without this the kernel can't complete
        // PCI device setup, which leaves BAR resources unclaimed. The mask selects
        // the two slot bits (0x1800) and the 3 pin bits (0x07).
        b.propCells("interrupt-map-mask", &.{ 0x1800, 0, 0, 0x07 });
        var imap: [4 * 4 * 10]u32 = undefined;
        var n: usize = 0;
        var slot: u32 = 0;
        while (slot < 4) : (slot += 1) {
            var pin: u32 = 1;
            while (pin <= 4) : (pin += 1) {
                const spi = arm.pci_intx_spi + ((slot + pin - 1) % 4);
                const cells = [_]u32{
                    slot << 11, 0, 0, // child unit address (slot in [15:11])
                    pin, // child interrupt pin (INTA..INTD)
                    GIC_PHANDLE, // interrupt parent
                    0, 0, // parent address (GIC #address-cells = 2)
                    0, spi, 0x04, // GIC: SPI, number, level-high
                };
                @memcpy(imap[n..][0..cells.len], &cells);
                n += cells.len;
            }
        }
        b.propCells("interrupt-map", imap[0..n]);
        b.endNode();
    }

    b.endNode(); // root
    return b.finish(out);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn be32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

test "virt DTB has a valid FDT header" {
    var out: [8192]u8 = undefined;
    const n = buildVirt(&out, .{ .cmdline = "console=ttyAMA0", .mem_base = 0x4000_0000, .mem_size = 0x0800_0000 });
    try testing.expectEqual(@as(u32, FDT_MAGIC), be32(&out, 0));
    try testing.expectEqual(@as(u32, @intCast(n)), be32(&out, 4)); // totalsize
    try testing.expectEqual(@as(u32, FDT_VERSION), be32(&out, 20));
    try testing.expectEqual(@as(u32, FDT_LAST_COMP), be32(&out, 24));
    const struct_off = be32(&out, 8);
    const strings_off = be32(&out, 12);
    try testing.expectEqual(@as(u32, HEADER_SIZE + RSVMAP_SIZE), struct_off);
    try testing.expect(strings_off > struct_off and n >= strings_off);
    // The reservation map is a single empty terminator.
    try testing.expectEqual(@as(u32, HEADER_SIZE), be32(&out, 16)); // off_mem_rsvmap
}

test "structure block is well-formed and balanced" {
    var out: [8192]u8 = undefined;
    _ = buildVirt(&out, .{ .cmdline = "x", .mem_base = 0x4000_0000, .mem_size = 0x0800_0000 });
    const struct_off = be32(&out, 8);
    const struct_len = be32(&out, 36);

    var pos: usize = struct_off;
    const end = struct_off + struct_len;
    var depth: i32 = 0;
    var saw_end = false;
    try testing.expectEqual(FDT_BEGIN_NODE, be32(&out, pos)); // first token opens root
    while (pos < end) {
        const tok = be32(&out, pos);
        pos += 4;
        switch (tok) {
            FDT_BEGIN_NODE => {
                depth += 1;
                while (out[pos] != 0) pos += 1; // skip name
                pos += 1;
                pos = std.mem.alignForward(usize, pos, 4);
            },
            FDT_END_NODE => depth -= 1,
            FDT_PROP => {
                const vlen = be32(&out, pos);
                pos += 8; // len + nameoff
                pos += std.mem.alignForward(usize, vlen, 4);
            },
            FDT_END => {
                saw_end = true;
                break;
            },
            else => return error.BadToken,
        }
        try testing.expect(depth >= 0);
    }
    try testing.expect(saw_end);
    try testing.expectEqual(@as(i32, 0), depth);
}

test "virt DTB carries the cmdline and key device nodes" {
    var out: [8192]u8 = undefined;
    const n = buildVirt(&out, .{ .cmdline = "console=ttyAMA0 root=/dev/ram0", .mem_base = 0x4000_0000, .mem_size = 0x0800_0000 });
    const blob = out[0..n];
    // The struct block holds node names and string-valued props; the strings
    // block holds property names. Substring checks span both.
    try testing.expect(std.mem.indexOf(u8, blob, "console=ttyAMA0 root=/dev/ram0") != null);
    try testing.expect(std.mem.indexOf(u8, blob, "arm,pl011") != null);
    try testing.expect(std.mem.indexOf(u8, blob, "arm,gic-v3") != null);
    try testing.expect(std.mem.indexOf(u8, blob, "arm,armv8-timer") != null);
    try testing.expect(std.mem.indexOf(u8, blob, "arm,psci-0.2") != null);
    try testing.expect(std.mem.indexOf(u8, blob, "memory@40000000") != null);
    // Property names are interned once in the strings block.
    try testing.expect(std.mem.indexOf(u8, blob, "compatible") != null);
    try testing.expect(std.mem.indexOf(u8, blob, "interrupts") != null);
}

test "chosen rng-seed appears when provided and is omitted when empty" {
    var out: [8192]u8 = undefined;
    const seed = [_]u8{0xA5} ** 64; // recognizable non-zero payload
    var n = buildVirt(&out, .{ .cmdline = "c", .mem_base = 0x4000_0000, .mem_size = 0x0800_0000, .rng_seed = &seed });
    var blob = out[0..n];
    try testing.expect(std.mem.indexOf(u8, blob, "rng-seed") != null); // property name interned
    try testing.expect(std.mem.indexOf(u8, blob, &seed) != null); // the 64 seed bytes verbatim
    // Fail closed: no host entropy -> no property (never credit a predictable seed).
    n = buildVirt(&out, .{ .cmdline = "c", .mem_base = 0x4000_0000, .mem_size = 0x0800_0000 });
    blob = out[0..n];
    try testing.expect(std.mem.indexOf(u8, blob, "rng-seed") == null);
}

test "vmgenid node appears with reg + edge interrupt when an address is given, omitted otherwise" {
    var out: [8192]u8 = undefined;
    var n = buildVirt(&out, .{ .cmdline = "c", .mem_base = 0x4000_0000, .mem_size = 0x0800_0000, .vmgenid_addr = 0x47ff_c000 });
    var blob = out[0..n];
    try testing.expect(std.mem.indexOf(u8, blob, "microsoft,vmgenid") != null);
    try testing.expect(std.mem.indexOf(u8, blob, "vmgenid@47ffc000") != null);
    // Absent when no address is reserved.
    n = buildVirt(&out, .{ .cmdline = "c", .mem_base = 0x4000_0000, .mem_size = 0x0800_0000 });
    blob = out[0..n];
    try testing.expect(std.mem.indexOf(u8, blob, "microsoft,vmgenid") == null);
}

test "v2m MSI frame and msi-parent appear when an MSI config is given" {
    var out: [8192]u8 = undefined;
    const n = buildVirt(&out, .{
        .cmdline = "x",
        .mem_base = 0x4000_0000,
        .mem_size = 0x0800_0000,
        .pcie = .{
            .ecam_base = arm.ecam_base,    .ecam_size = arm.ecam_size,
            .io_base = arm.pci_io_base,    .io_size = arm.pci_io_size,
            .mmio_base = arm.pci_mmio_base, .mmio_size = arm.pci_mmio_size,
            .mmio64_base = arm.pci_mmio64_base, .mmio64_size = arm.pci_mmio64_size,
        },
        .msi = .{ .doorbell_base = arm.msi_base, .doorbell_size = 0x1000, .spi_base = 955, .spi_count = 64 },
    });
    const blob = out[0..n];
    try testing.expect(std.mem.indexOf(u8, blob, "arm,gic-v2m-frame") != null);
    try testing.expect(std.mem.indexOf(u8, blob, "arm,msi-base-spi") != null);
    try testing.expect(std.mem.indexOf(u8, blob, "msi-parent") != null);
    // Structure must remain balanced with the extra GIC child + pcie prop.
    const struct_off = be32(&out, 8);
    const struct_len = be32(&out, 36);
    var pos: usize = struct_off;
    const end = struct_off + struct_len;
    var depth: i32 = 0;
    while (pos < end) {
        const tok = be32(&out, pos);
        pos += 4;
        switch (tok) {
            FDT_BEGIN_NODE => {
                depth += 1;
                while (out[pos] != 0) pos += 1;
                pos = std.mem.alignForward(usize, pos + 1, 4);
            },
            FDT_END_NODE => depth -= 1,
            FDT_PROP => {
                const vlen = be32(&out, pos);
                pos += 8 + std.mem.alignForward(usize, vlen, 4);
            },
            FDT_END => break,
            else => return error.BadToken,
        }
    }
    try testing.expectEqual(@as(i32, 0), depth);
}

test "property names are deduplicated in the strings block" {
    var sbuf: [256]u8 = undefined;
    var strbuf: [64]u8 = undefined;
    var b = Builder.init(&sbuf, &strbuf);
    b.beginNode("a");
    b.propU32("reg", 1);
    b.endNode();
    b.beginNode("b");
    b.propU32("reg", 2); // same name -> same offset, not appended twice
    b.endNode();
    var out: [512]u8 = undefined;
    _ = b.finish(&out);
    try testing.expectEqual(@as(usize, "reg".len + 1), b.strlen);
}
