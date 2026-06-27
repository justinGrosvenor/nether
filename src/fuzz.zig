//! Deterministic fuzz-smoke for Nether's guest-facing parsers.
//!
//! Covered: the VT parser + screen grid, the virtqueue descriptor walk, the
//! virtio-vsock / virtio-net / virtio-gpu device parsers (incl. the gpu control-queue
//! commands and live framebuffer capture - the richest attacker-controlled input), and
//! the I/O access surfaces: PCI config space (ECAM) and the virtio BAR MMIO regions, at
//! every guest-chosen access width (incl. oversized); the slirp user-mode network stack
//! (guest frames: Ethernet/ARP/IPv4/ICMP/UDP/DHCP/TCP, with a deny-all firewall so no
//! host sockets are opened); and the ELF/PVH boot-image loader. (The file-transfer reply
//! parser is fuzzed in control.zig, where its Capture type lives.)
//!
//! These parse attacker-controlled bytes (a guest's serial output, and the
//! descriptor rings a guest writes into shared memory), so the contract under
//! test is the security posture from docs/design.md: parsing ANY byte string
//! must *terminate* and stay in bounds, never crash, hang, or read/write
//! outside guest memory. Seeds are fixed so a failure reproduces exactly.
//!
//! This is the always-on smoke that runs with `zig build test` (it surfaces
//! panics under Debug/ReleaseSafe). A full AFL-style `zig build fuzz` target is
//! a later D5 item. Pattern borrowed from a private path tests/fuzz.zig.

const std = @import("std");
const Parser = @import("vt/Parser.zig");
const Screen = @import("vt/Screen.zig");
const virtq = @import("virtio/virtq.zig");
const virtio = @import("virtio/virtio.zig");
const vsock = @import("virtio/virtio_vsock.zig");
const net = @import("virtio/virtio_net.zig");
const gpu = @import("virtio/virtio_gpu.zig");
const pci = @import("chipset/pci.zig");
const elf = @import("boot/elf.zig");
const slirp = @import("net/slirp.zig");

// --- VT parser -------------------------------------------------------------

/// Drive every byte through the parser. The parser is zero-alloc (fixed param
/// and intermediate arrays, fixed OSC buffer), so the only failure mode is a
/// safety trip, which a panic under Debug would catch. We touch each emitted
/// action so the work cannot be optimized away.
fn feedParser(bytes: []const u8) void {
    var p = Parser.init();
    defer p.deinit();
    for (bytes) |b| {
        const actions = p.next(b);
        for (actions) |maybe| if (maybe) |a| std.mem.doNotOptimizeAway(a);
    }
}

test "vt parser survives random bytes" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        var buf: [128]u8 = undefined;
        const n = rand.uintLessThan(usize, buf.len);
        rand.bytes(buf[0..n]);
        feedParser(buf[0..n]);
    }
}

test "vt parser survives random escape-heavy tokens" {
    // Bias toward the bytes that drive state transitions (ESC, CSI/OSC/DCS
    // introducers, params, separators) so we exercise deep parser states, not
    // just the ground-state print path.
    const alphabet = "\x1b[]P;:0123456789?$ \x07\x9b\x9d\x90mHABCcqp\\";
    var prng = std.Random.DefaultPrng.init(0xBADC0DE);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        var buf: [256]u8 = undefined;
        const n = rand.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*b| b.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        feedParser(buf[0..n]);
    }
}

// --- screen grid -----------------------------------------------------------

// Drive random bytes through the full parse -> grid pipeline. The grid clamps
// every cursor motion and indexes a fixed buffer, so no input should ever index
// out of bounds; a safety trip is the only failure mode. Reuse one screen
// across inputs so scroll/erase/cursor state interleaves.
test "screen grid survives random escape-heavy bytes" {
    var s = try Screen.init(std.testing.allocator, 24, 80);
    defer s.deinit();
    const alphabet = "\x1b[]P;:0123456789?$ \r\n\x08\x09\x07Hmfcd ABCDJKsuhlABCXYZabcxyz";
    var prng = std.Random.DefaultPrng.init(0xD15EA5E);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        var buf: [256]u8 = undefined;
        const n = rand.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*b| b.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        s.write(buf[0..n]);
    }
    // The grid is still readable and in bounds after the assault.
    var row: u16 = 0;
    while (row < s.rows) : (row += 1) {
        var line: [400]u8 = undefined;
        std.mem.doNotOptimizeAway(s.rowText(row, &line));
    }
}

test "screen grid survives fully random bytes" {
    var s = try Screen.init(std.testing.allocator, 8, 16);
    defer s.deinit();
    var prng = std.Random.DefaultPrng.init(0xF00DBABE);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        var buf: [128]u8 = undefined;
        const n = rand.uintLessThan(usize, buf.len);
        rand.bytes(buf[0..n]);
        s.write(buf[0..n]);
    }
}

// --- virtqueue -------------------------------------------------------------

/// Treat `ram` as fully attacker-controlled guest memory (it holds the avail
/// ring, descriptor table, and used ring) and run a device's consume loop over
/// it with a fixed, valid queue geometry. Every access is bounds-checked by
/// GuestMem and the chain walk is capped at the queue size, so this must always
/// terminate without an out-of-bounds access. The guard is belt-and-suspenders:
/// next() already advances last_avail each pop, so the loop is self-terminating.
fn feedVirtq(ram: []u8) void {
    const m = virtq.GuestMem{ .bytes = ram, .base = 0 };
    var vq = virtq.Virtqueue{ .size = 8, .desc = 0, .avail = 0x100, .used = 0x200 };
    var guard: usize = 0;
    while (vq.next(m)) |head| {
        var it = vq.chain(m, head);
        var written: u32 = 0;
        while (it.next()) |buf| {
            // Simulate the device touching the buffer through the bounds check.
            if (m.slice(buf.addr, buf.len)) |s| written +%= @intCast(s.len);
        }
        vq.complete(m, head, written);
        guard += 1;
        if (guard > 1 << 17) break;
    }
    std.mem.doNotOptimizeAway(vq.used_idx);
}

test "virtqueue survives hostile rings and descriptors" {
    // 1 KiB covers the fixed geometry: desc table (8*16), avail ring (0x100),
    // used ring (0x200). Filling it with random bytes is a hostile driver.
    var prng = std.Random.DefaultPrng.init(0x5CA1AB1E);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        var ram: [1024]u8 = undefined;
        rand.bytes(&ram);
        feedVirtq(&ram);
    }
}

test "virtqueue survives all-ones and all-zero memory" {
    // Boundary cases the PRNG is unlikely to hit: a zeroed ring (no work) and a
    // saturated ring (max indices/addresses, every NEXT flag set).
    var zero = [_]u8{0} ** 1024;
    feedVirtq(&zero);
    var ones = [_]u8{0xff} ** 1024;
    feedVirtq(&ones);
}

// --- vsock protocol engine -------------------------------------------------

// The packets a guest writes to its TX queue are attacker-controlled. The
// engine decodes a 44-byte header and reads at most the bytes that actually
// followed it, so any byte string must process without a safety trip. Reuse one
// engine across inputs (with a listened port) so the connection table, credit
// accounting, and staging ring interleave. The staging ring is drained each
// round so a flood of refusals cannot make peekOut/popOut diverge.
fn feedVsock(vs: *vsock.Vsock, bytes: []const u8) void {
    vs.rx(bytes);
    while (vs.peekOut()) |pkt| {
        std.mem.doNotOptimizeAway(pkt.len);
        vs.popOut();
    }
}

test "vsock engine survives random packets" {
    var vs = vsock.Vsock{ .guest_cid = 3 };
    _ = vs.listen(1024);
    var prng = std.Random.DefaultPrng.init(0x5E550CC);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        var buf: [128]u8 = undefined;
        const n = rand.uintLessThan(usize, buf.len);
        rand.bytes(buf[0..n]);
        feedVsock(&vs, buf[0..n]);
    }
}

test "vsock engine survives header-shaped fuzz" {
    // Bias toward well-formed-ish packets: real ops/ports/cids in the header so
    // the connection state machine is driven deep (REQUEST/RW/SHUTDOWN/credit),
    // not just rejected at decode.
    var vs = vsock.Vsock{ .guest_cid = 3 };
    _ = vs.listen(7);
    var prng = std.Random.DefaultPrng.init(0xACED5E5);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        var buf: [vsock.HDR_LEN + 64]u8 = undefined;
        const payload = rand.uintLessThan(usize, 64);
        const h = vsock.Hdr{
            .src_cid = 3,
            .dst_cid = vsock.HOST_CID,
            .src_port = rand.uintLessThan(u32, 4),
            .dst_port = if (rand.boolean()) 7 else rand.uintLessThan(u32, 4),
            .len = rand.uintLessThan(u32, 4096),
            .op = rand.uintLessThan(u16, 9),
            .flags = rand.uintLessThan(u32, 4),
            .buf_alloc = rand.uintLessThan(u32, 1 << 16),
            .fwd_cnt = rand.uintLessThan(u32, 1 << 16),
        };
        h.encode(buf[0..vsock.HDR_LEN]);
        rand.bytes(buf[vsock.HDR_LEN..][0..payload]);
        feedVsock(&vs, buf[0 .. vsock.HDR_LEN + payload]);
    }
}

// --- virtio-net device -----------------------------------------------------

// Both net datapaths walk attacker-controlled guest descriptors: the TX kick
// gathers a guest-built chain, and pushRx scatters into guest-posted RX buffers.
// Every guest access is bounds-checked by GuestMem and the chain walk is capped
// at the queue size, so a hostile ring must process without a safety trip. The
// avail indices are bounded so the drain loop stays cheap; the ring contents,
// descriptors, and buffer addresses are fully random.
//   TX queue 1: desc 0x000, avail 0x100, used 0x180
//   RX queue 0: desc 0x200, avail 0x300, used 0x380
fn netSink(ctx: *anyopaque, frame: []const u8) void {
    _ = ctx;
    std.mem.doNotOptimizeAway(frame.len);
}

fn feedNet(ram: []u8, frame: []const u8) void {
    var n = net.Net{ .on_tx = netSink };
    var dev = virtio.Device.init(n.backend(), .{ .bytes = ram, .base = 0 });
    n.attach(&dev);
    dev.barWrite(0x16, 2, net.TXQ); // TX queue geometry
    dev.barWrite(0x18, 2, 8);
    dev.barWrite(0x20, 4, 0x000);
    dev.barWrite(0x28, 4, 0x100);
    dev.barWrite(0x30, 4, 0x180);
    dev.barWrite(0x1c, 2, 1);
    dev.barWrite(0x16, 2, net.RXQ); // RX queue geometry
    dev.barWrite(0x18, 2, 8);
    dev.barWrite(0x20, 4, 0x200);
    dev.barWrite(0x28, 4, 0x300);
    dev.barWrite(0x30, 4, 0x380);
    dev.barWrite(0x1c, 2, 1);
    dev.barWrite(0x2000, 4, net.TXQ); // kick TX: drain the hostile TX ring
    _ = n.pushRx(frame); // place a frame into the hostile RX ring
    std.mem.doNotOptimizeAway(dev.isr);
}

test "virtio-net survives hostile rings and frames" {
    var prng = std.Random.DefaultPrng.init(0x4E700FF);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        var ram: [4096]u8 = undefined;
        rand.bytes(&ram);
        // Bound the avail indices so the TX drain stays cheap; the rest is random.
        std.mem.writeInt(u16, ram[0x102..][0..2], rand.uintLessThan(u16, 16), .little);
        std.mem.writeInt(u16, ram[0x302..][0..2], rand.uintLessThan(u16, 16), .little);
        var frame: [128]u8 = undefined;
        const flen = rand.uintLessThan(usize, frame.len);
        rand.bytes(frame[0..flen]);
        feedNet(&ram, frame[0..flen]);
    }
}

// --- virtio-gpu device -----------------------------------------------------

// The control queue parses the richest attacker-controlled input in the tree: a
// guest command chain whose header, resource ids, dimensions, scatter-gather backing
// entry count, and entry addr/len are all guest-set. Then the capture path (frame /
// frameDiff) reads the (possibly hostile) backing live. Every id/count/dim/address is
// bounds-checked; a malformed command must process and capture without a safety trip.

// Drive a single hostile command through the real notify -> gather -> dispatch ->
// scatter -> complete path, then exercise the capture path against the state it left.
fn feedGpuCmd(ram: []u8, cmd: []const u8) void {
    @memset(ram, 0);
    var g = gpu.Gpu{};
    var dev = virtio.Device.init(g.backend(), .{ .bytes = ram, .base = 0 });
    g.attach(&dev);
    // A 2-descriptor chain on the control queue: desc0 -> readable command buffer
    // (0x400), desc1 -> writable response buffer (0x800).
    const clen: u32 = @intCast(@min(cmd.len, 0x400));
    std.mem.writeInt(u64, ram[0x000..][0..8], 0x400, .little); // desc0.addr
    std.mem.writeInt(u32, ram[0x008..][0..4], clen, .little); // desc0.len
    std.mem.writeInt(u16, ram[0x00c..][0..2], 1, .little); // desc0.flags = NEXT
    std.mem.writeInt(u16, ram[0x00e..][0..2], 1, .little); // desc0.next = 1
    std.mem.writeInt(u64, ram[0x010..][0..8], 0x800, .little); // desc1.addr
    std.mem.writeInt(u32, ram[0x018..][0..4], 256, .little); // desc1.len
    std.mem.writeInt(u16, ram[0x01c..][0..2], 2, .little); // desc1.flags = WRITE
    std.mem.writeInt(u16, ram[0x100..][0..2], 0, .little); // avail.flags
    std.mem.writeInt(u16, ram[0x102..][0..2], 1, .little); // avail.idx
    std.mem.writeInt(u16, ram[0x104..][0..2], 0, .little); // avail.ring[0] = head 0
    @memcpy(ram[0x400..][0..clen], cmd[0..clen]);

    dev.barWrite(0x16, 2, gpu.CONTROLQ);
    dev.barWrite(0x18, 2, 8); // queue size
    dev.barWrite(0x20, 4, 0x000); // desc
    dev.barWrite(0x28, 4, 0x100); // avail
    dev.barWrite(0x30, 4, 0x180); // used
    dev.barWrite(0x1c, 2, 1); // enable
    dev.barWrite(0x2000, 4, gpu.CONTROLQ); // kick: drain + dispatch the hostile command

    // Capture against whatever (hostile) scanout/backing state the command left. Both
    // bound to the passed buffers, so a huge guest dimension just yields 0.
    var out: [16384]u8 = undefined;
    var shadow: [4096]u8 = undefined;
    std.mem.doNotOptimizeAway(g.frame(&out));
    std.mem.doNotOptimizeAway(g.frameDiff(&shadow, &out));
}

// The real virtio-gpu command types; biasing cmd_type to these exercises the actual
// per-command parsers (not just the ERR_UNSPEC default) with hostile field values.
const GPU_CMDS = [_]u32{ 0x0100, 0x0101, 0x0102, 0x0103, 0x0104, 0x0105, 0x0106, 0x0107, 0x0300, 0x0301, 0xdead_beef };

test "virtio-gpu survives header-shaped hostile commands + capture" {
    var prng = std.Random.DefaultPrng.init(0x69_70_75);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 6000) : (i += 1) {
        var cmd: [512]u8 = undefined;
        const len = 24 + rand.uintLessThan(usize, cmd.len - 24); // always >= a full header
        rand.bytes(cmd[0..len]);
        // Bias the type to a real command so the actual parsers run; the 24-byte
        // header and all command fields (ids, dims, nr_entries, entry addr/len) stay
        // random/hostile.
        std.mem.writeInt(u32, cmd[0..4], GPU_CMDS[rand.uintLessThan(usize, GPU_CMDS.len)], .little);
        var ram: [4096]u8 = undefined;
        feedGpuCmd(&ram, cmd[0..len]);
    }
}

test "virtio-gpu survives fully hostile control/cursor rings" {
    // Pure-random rings on BOTH queues (the control + cursor drain paths), exercising
    // the descriptor walk + dispatch with no structure at all.
    var prng = std.Random.DefaultPrng.init(0x6_C0_FF_EE);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        var ram: [4096]u8 = undefined;
        rand.bytes(&ram);
        var g = gpu.Gpu{};
        var dev = virtio.Device.init(g.backend(), .{ .bytes = &ram, .base = 0 });
        g.attach(&dev);
        // control queue 0: desc 0x000 / avail 0x100 / used 0x180
        dev.barWrite(0x16, 2, gpu.CONTROLQ);
        dev.barWrite(0x18, 2, 8);
        dev.barWrite(0x20, 4, 0x000);
        dev.barWrite(0x28, 4, 0x100);
        dev.barWrite(0x30, 4, 0x180);
        dev.barWrite(0x1c, 2, 1);
        // cursor queue 1: desc 0x200 / avail 0x300 / used 0x380
        dev.barWrite(0x16, 2, gpu.CURSORQ);
        dev.barWrite(0x18, 2, 8);
        dev.barWrite(0x20, 4, 0x200);
        dev.barWrite(0x28, 4, 0x300);
        dev.barWrite(0x30, 4, 0x380);
        dev.barWrite(0x1c, 2, 1);
        // Bound the avail indices so the drains stay cheap; the rest is random.
        std.mem.writeInt(u16, ram[0x102..][0..2], rand.uintLessThan(u16, 16), .little);
        std.mem.writeInt(u16, ram[0x302..][0..2], rand.uintLessThan(u16, 16), .little);
        dev.barWrite(0x2000, 4, gpu.CONTROLQ);
        dev.barWrite(0x2000, 4, gpu.CURSORQ);
        std.mem.doNotOptimizeAway(dev.isr);
    }
}

// --- PCI config space (ECAM) -----------------------------------------------

// The guest drives ECAM config accesses of guest-chosen WIDTH at guest-chosen
// register offsets. A width > 4 (a 64-bit ECAM load) must not panic: the config-read
// callbacks bound their byte-assembly shift to the u32 result (i < 4). This drives
// reads AND writes of widths 1..8 at every register offset through the real bus path.
test "pci config space survives oversized and odd-width accesses" {
    var ram: [4096]u8 = undefined;
    @memset(&ram, 0);
    var nb = net.Net{ .on_tx = netSink };
    var dev = virtio.Device.init(nb.backend(), .{ .bytes = &ram, .base = 0 });
    nb.attach(&dev);
    var host = pci.Host{};
    try host.addFunction(dev.function(3, 0));
    const mm = host.mmioDevice();

    var prng = std.Random.DefaultPrng.init(0xC0FFEE_11);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        const dnum: u64 = rand.uintLessThan(u64, 4); // device 0..3 (3 is ours, 0..2 absent)
        const reg: u64 = rand.uintLessThan(u64, 0x1000); // any 12-bit register offset
        const offset = (dnum << 15) | reg;
        const width = 1 + rand.uintLessThan(usize, 8); // 1..8 bytes, incl. the oversized case
        var buf: [8]u8 = undefined;
        if (rand.boolean()) {
            mm.read_fn(mm.ptr, offset, buf[0..width]);
        } else {
            rand.bytes(buf[0..width]);
            mm.write_fn(mm.ptr, offset, buf[0..width]);
        }
        std.mem.doNotOptimizeAway(buf);
    }
}

// --- virtio BAR MMIO read surface ------------------------------------------

// The guest reads the device BAR at any offset and width: common config (0..0x1000),
// the ISR byte, the device-specific config region (-> backend.config_read, where the
// oversized-read panic lived), the MSI-X table, and the PBA. Every region must answer
// a read of width 1..8 without a safety trip. Reads have no notify side effects, so
// this stays fast and focused on the audited read path.
test "virtio BAR MMIO reads survive every offset and width" {
    var ram: [4096]u8 = undefined;
    @memset(&ram, 0);
    var nb = net.Net{ .on_tx = netSink };
    var dev = virtio.Device.init(nb.backend(), .{ .bytes = &ram, .base = 0 });
    nb.attach(&dev);
    var prng = std.Random.DefaultPrng.init(0xBA12_EAD);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 30000) : (i += 1) {
        const off = rand.uintLessThan(u64, 0x6000); // spans common/isr/notify/cfg/msix/pba
        const width: u8 = @intCast(1 + rand.uintLessThan(usize, 8)); // 1..8, incl. oversized
        std.mem.doNotOptimizeAway(dev.barRead(off, width));
        // Also fuzz the MSI-X table + common-config WRITE side (no notify -> no drain):
        // pick a safe write region so we never kick a queue here.
        if (rand.boolean()) {
            const woff: u64 = if (rand.boolean()) rand.uintLessThan(u64, 0x1000) else 0x4000 + rand.uintLessThan(u64, 0x2000);
            dev.barWrite(woff, width, rand.int(u32));
        }
    }
    std.mem.doNotOptimizeAway(dev.isr);
}

// --- ELF / PVH boot loader -------------------------------------------------

// elf.loadPvh parses a structured binary (ELF header -> program headers -> PT_LOAD
// segments + the PVH note). The image is operator-supplied, not guest-supplied, but
// a malformed/corrupt vmlinux must still error cleanly, never read out of bounds or
// overflow. We drive it with a PERMISSIVE writer (records, does not bounds-check),
// which removes the production writer's masking so the loader's own arithmetic safety
// is what's under test - e.g. a huge p_paddr in a PT_LOAD must not overflow the .bss
// start computation.
const ElfSink = struct {
    pub fn write(self: *ElfSink, gpa: u64, bytes: []const u8) !void {
        _ = self;
        std.mem.doNotOptimizeAway(gpa);
        std.mem.doNotOptimizeAway(bytes.len);
    }
    pub fn zero(self: *ElfSink, gpa: u64, len: usize) !void {
        _ = self;
        std.mem.doNotOptimizeAway(gpa);
        std.mem.doNotOptimizeAway(len);
    }
};

test "ELF/PVH loader survives malformed and hostile images" {
    var prng = std.Random.DefaultPrng.init(0xE1F_F022);
    const rand = prng.random();
    var sink = ElfSink{};
    var i: usize = 0;
    while (i < 12000) : (i += 1) {
        var img = [_]u8{0} ** 512;
        const len = 1 + rand.uintLessThan(usize, img.len);
        rand.bytes(img[0..len]);

        // Half the rounds: build a well-formed-enough ELF so parsing reaches the phdr
        // loop with PT_LOAD/PT_NOTE entries carrying hostile field values (full-range
        // p_paddr/p_memsz, valid-but-random p_offset/p_filesz). This is what exercises
        // the segment-bound + .bss-start paths, not just the early header rejects.
        if (len >= 320 and rand.boolean()) {
            @memset(img[0..len], 0);
            @memcpy(img[0..4], "\x7fELF");
            img[4] = 2; // ELFCLASS64
            img[5] = 1; // little-endian
            std.mem.writeInt(u16, img[18..20], 62, .little); // EM_X86_64
            const phoff: usize = 64;
            const phnum: usize = 1 + rand.uintLessThan(usize, 4); // <= 4 -> table fits in 512
            std.mem.writeInt(u64, img[32..40], phoff, .little);
            std.mem.writeInt(u16, img[54..56], 56, .little); // phentsize
            std.mem.writeInt(u16, img[56..58], @intCast(phnum), .little);
            var k: usize = 0;
            while (k < phnum) : (k += 1) {
                const ph = phoff + k * 56;
                const ptype = ([_]u32{ 1, 4, 0, 0xdead_beef })[rand.uintLessThan(usize, 4)]; // PT_LOAD/PT_NOTE/...
                const p_offset = rand.uintLessThan(u64, len);
                const p_filesz = rand.uintLessThan(u64, len - @as(usize, @intCast(p_offset)) + 1);
                // p_paddr: bias toward the top of the u64 range so `p_paddr + p_filesz`
                // (the .bss start) actually exercises the overflow path, not just random
                // values that almost never reach it.
                const p_paddr = if (rand.boolean()) std.math.maxInt(u64) - rand.uintLessThan(u64, 1024) else rand.int(u64);
                std.mem.writeInt(u32, img[ph + 0 ..][0..4], ptype, .little);
                std.mem.writeInt(u64, img[ph + 8 ..][0..8], p_offset, .little);
                std.mem.writeInt(u64, img[ph + 24 ..][0..8], p_paddr, .little);
                std.mem.writeInt(u64, img[ph + 32 ..][0..8], p_filesz, .little);
                std.mem.writeInt(u64, img[ph + 40 ..][0..8], rand.int(u64), .little); // p_memsz: full range
            }
        }
        _ = elf.loadPvh(img[0..len], &sink) catch {};
    }
}

// --- slirp user-mode network stack -----------------------------------------

// onGuestFrame parses fully guest-controlled frames - the largest attacker surface
// in the tree: Ethernet -> ARP / IPv4 -> ICMP / UDP (incl. DHCP) / TCP, plus the reply
// builders that write into a fixed scratch buffer from guest-derived lengths. We set a
// deny-all egress firewall (addBlock 0.0.0.0/0) so the outbound NAT paths short-circuit
// BEFORE creating any host socket - the fuzz exercises only the in-VMM parsing/build
// code, no real network I/O. Every length/offset is bounds-checked; a hostile frame
// must process without a safety trip.
fn slirpSink(ctx: *anyopaque, frame: []const u8) void {
    _ = ctx;
    std.mem.doNotOptimizeAway(frame.len);
}

test "slirp survives fully random guest frames" {
    var s = slirp.Slirp{};
    _ = s.addBlock("0.0.0.0/0"); // deny all egress -> no host sockets are opened
    s.out_fn = slirpSink;
    s.out_ctx = &s;
    var prng = std.Random.DefaultPrng.init(0x5117_F0FF);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 8000) : (i += 1) {
        var frame: [256]u8 = undefined;
        const n = rand.uintLessThan(usize, frame.len);
        rand.bytes(frame[0..n]);
        s.onGuestFrame(frame[0..n]);
    }
}

test "slirp survives structured-hostile IPv4 frames (random ihl/proto/doff)" {
    var s = slirp.Slirp{};
    _ = s.addBlock("0.0.0.0/0");
    s.out_fn = slirpSink;
    s.out_ctx = &s;
    var prng = std.Random.DefaultPrng.init(0x14_BADD_11);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 12000) : (i += 1) {
        var frame: [256]u8 = undefined;
        const n = 14 + rand.uintLessThan(usize, frame.len - 14); // always a full Ethernet hdr
        rand.bytes(frame[0..n]);
        // Ethernet: ARP or IPv4 so we reach the sub-parsers, not the early reject.
        // Ethertype is big-endian on the wire (slirp's rd16 reads .big).
        const ethertype: u16 = if (rand.boolean()) 0x0800 else 0x0806;
        std.mem.writeInt(u16, frame[12..14], ethertype, .big);
        if (ethertype == 0x0800 and n >= 14 + 20) {
            // IPv4 header with a random-but-plausible IHL and a real protocol so the
            // ICMP/UDP/TCP sub-parsers (and their reply builders) actually run.
            const ihl_words: u8 = 5 + rand.uintLessThan(u8, 6); // 5..10 -> 20..40 bytes
            frame[14] = (4 << 4) | ihl_words; // version 4, IHL
            frame[14 + 9] = ([_]u8{ 1, 6, 17, 99 })[rand.uintLessThan(usize, 4)]; // ICMP/TCP/UDP/other
            // leave dst IP random; the deny-all firewall blocks egress regardless.
        }
        s.onGuestFrame(frame[0..n]);
    }
}
