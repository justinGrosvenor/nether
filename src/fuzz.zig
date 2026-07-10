//! Deterministic fuzz-smoke for Nether's guest-facing parsers.
//!
//! Covered: the VT parser + screen grid, the virtqueue descriptor walk, the
//! virtio-vsock / virtio-net / virtio-gpu / virtio-blk device parsers (incl. the gpu
//! control-queue commands and live framebuffer capture - the richest attacker-controlled
//! input, and the blk sector arithmetic against a canary-guarded disk), fw_cfg's
//! guest-streamed selector/offset, the control-plane relay exit-trailer scanner, the
//! snapshot vsock engine-state validator (an operator-supplied base file: validState must
//! gate every byte pattern so import + drain stays in bounds), and
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
//! Two layers: (1) always-on fixed-seed smoke (the `survives ...` tests) that runs
//! with `zig build test` and surfaces panics under Debug/ReleaseSafe, reproducibly;
//! (2) coverage-guided entry points (the `fuzz: ...` tests, via std.testing.fuzz) that
//! `zig build fuzz --fuzz` drives over the same harnesses, following the standard
//! std.testing.fuzz layout.

const std = @import("std");
const Parser = @import("vt/Parser.zig");
const Screen = @import("vt/Screen.zig");
const virtq = @import("virtio/virtq.zig");
const virtio = @import("virtio/virtio.zig");
const vsock = @import("virtio/virtio_vsock.zig");
const control = @import("agent/control.zig");
const snapshot = @import("agent/snapshot.zig");
const pl031 = @import("chipset/pl031.zig");
const net = @import("virtio/virtio_net.zig");
const gpu = @import("virtio/virtio_gpu.zig");
const blk = @import("virtio/virtio_blk.zig");
const fw_cfg = @import("chipset/fw_cfg.zig");
const pci = @import("chipset/pci.zig");
const elf = @import("boot/elf.zig");
const slirp = @import("net/slirp.zig");

const Prng = std.Random.DefaultPrng;

/// Seed a fixed-seed smoke harness. With no environment override this returns the exact
/// `default` seed, so `zig build test` stays fully deterministic and reproducible. When
/// NETHER_FUZZ_SEED is set (the random pass of scripts/fuzz.sh) the base seed is mixed in,
/// so every harness explores a fresh input stream each run while staying distinct per
/// target. A failing random run reproduces by re-exporting the same NETHER_FUZZ_SEED.
fn fuzzPrng(default: u64) Prng {
    const raw = std.c.getenv("NETHER_FUZZ_SEED") orelse return Prng.init(default);
    const salt = std.fmt.parseInt(u64, std.mem.sliceTo(raw, 0), 0) catch 0; // base 0: 0x.. or decimal
    return Prng.init(default ^ salt);
}

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
    var prng = fuzzPrng(0xC0FFEE);
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
    var prng = fuzzPrng(0xBADC0DE);
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
    var prng = fuzzPrng(0xD15EA5E);
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
    var prng = fuzzPrng(0xF00DBABE);
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
        var bufs: usize = 0;
        while (it.next()) |buf| {
            bufs += 1;
            // Simulate the device touching the buffer through the bounds check.
            if (m.slice(buf.addr, buf.len)) |s| written +%= @intCast(s.len);
        }
        // Invariant: the circular-chain guard caps every walk at the queue size, so a
        // self-referential or over-long descriptor chain can never iterate unbounded.
        std.debug.assert(bufs <= vq.size);
        vq.complete(m, head, written);
        guard += 1;
        if (guard > 1 << 17) break;
    }
    std.mem.doNotOptimizeAway(vq.used_idx);
}

test "virtqueue survives hostile rings and descriptors" {
    // 1 KiB covers the fixed geometry: desc table (8*16), avail ring (0x100),
    // used ring (0x200). Filling it with random bytes is a hostile driver.
    var prng = fuzzPrng(0x5CA1AB1E);
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
    // Invariant: after processing any packet the staging ring stays within bounds - the
    // same contract validState enforces on a restored engine (out_count/head/tail feed
    // direct out[] access in peekOut/pushOut). A hostile packet stream must never push it
    // out of range.
    std.debug.assert(vs.out_count <= vs.out.len);
    std.debug.assert(vs.out_head < vs.out.len and vs.out_tail < vs.out.len);
    while (vs.peekOut()) |pkt| {
        std.mem.doNotOptimizeAway(pkt.len);
        vs.popOut();
    }
    std.debug.assert(!vs.pendingOut()); // fully drained: peekOut and popOut agree
}

test "vsock engine survives random packets" {
    var vs = vsock.Vsock{ .guest_cid = 3 };
    _ = vs.listen(1024);
    var prng = fuzzPrng(0x5E550CC);
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
    var prng = fuzzPrng(0xACED5E5);
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

// --- vsock snapshot engine state -------------------------------------------

// A restored base snapshot carries the vsock engine State (connection table, listen
// registry, staging ring) read RAW from an operator-supplied file - a base that is
// truncated, bit-flipped, or version-drifted on disk. validState gates it before import;
// the security contract is that validState(s)==true IMPLIES importing it and then
// draining / operating the engine stays in bounds (the ring indices feed direct out[]
// access in peekOut/pushOut and each len slices buf[0..len]). So: feed an arbitrary State,
// a rejected one is a no-op, and an accepted one must import + fully drain + take host
// actions (which index conns[]/out[]) without a safety trip.
fn feedVsockState(st: *const vsock.Vsock.State) void {
    if (!vsock.Vsock.validState(st)) return; // a corrupt base is refused before import
    var eng = vsock.Vsock{ .guest_cid = 3 };
    eng.importState(st);
    var guard: usize = 0;
    while (eng.peekOut()) |pkt| { // drain the staging ring; must stay in bounds
        std.mem.doNotOptimizeAway(pkt.len);
        eng.popOut();
        guard += 1;
        if (guard > 4 * 64) break; // out_count <= OUT_RING after validState; backstop
    }
    std.mem.doNotOptimizeAway(eng.send(0, "x")); // host actions index conns[]/out[]
    std.mem.doNotOptimizeAway(eng.pendingOut());
    eng.close(0);
}

test "vsock snapshot state import stays in bounds under validState" {
    // Target the validity-relevant fields directly (the staging ring control words and
    // packet lengths), spanning valid AND invalid ranges, so both the reject path and
    // the accept-then-drain path are exercised cheaply (the full State is ~200 KiB; we
    // don't randomize all of it here - the coverage-guided entry below does that).
    var prng = fuzzPrng(0x5A_AF_11_5E);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        var st = vsock.Vsock.State{ .guest_cid = 3 };
        st.out_head = rand.uintLessThan(usize, 128); // 0..127: spans valid (<64) and OOB (>=64)
        st.out_tail = rand.uintLessThan(usize, 128);
        st.out_count = rand.uintLessThan(usize, 128);
        for (&st.out) |*p| p.len = rand.uintLessThan(u32, 8192); // spans valid (<=PKT_CAP) and over
        feedVsockState(&st);
    }
}

// --- snapshot header (restore-file parser) ---------------------------------
//
// A snapshot file is operator/same-uid input (restore_from, validate_snapshot). The
// header gates all the section-offset arithmetic, so a hostile/corrupt header must never
// crash the validator nor be accepted with an out-of-bounds field (snapshot.fuzzHeader
// asserts that contract). Feed fully random headers plus near-valid ones (a real header
// with a few bytes flipped) so the accept path is actually reached, not just rejects.

fn goodHeader(hdr: *[128]u8) void {
    const hvfb = @import("hv/hvf_backend.zig");
    @memset(hdr, 0);
    std.mem.writeInt(u32, hdr[0..4], 0x4E455448, .little); // "NETH" magic (SNAP_MAGIC)
    std.mem.writeInt(u32, hdr[4..8], 4, .little); // SNAP_VERSION
    std.mem.writeInt(u32, hdr[8..12], 2, .little); // num_cpus
    std.mem.writeInt(u32, hdr[12..16], @sizeOf(hvfb.CpuState), .little);
    std.mem.writeInt(u64, hdr[24..32], 512 * 1024 * 1024, .little); // ram_size
    std.mem.writeInt(u32, hdr[56..60], @sizeOf(virtio.Device.DeviceState), .little);
    std.mem.writeInt(u32, hdr[60..64], @sizeOf(@import("chipset/pl011.zig").Pl011.State), .little);
}

test "snapshot header validation survives random + near-valid headers" {
    var prng = fuzzPrng(0x5417_4A11);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        var hdr: [128]u8 = undefined;
        if (i & 1 == 0) {
            rand.bytes(&hdr); // fully random
        } else {
            goodHeader(&hdr); // a valid header with a few bytes corrupted -> reach the accept path
            var f: usize = 0;
            const flips = rand.uintLessThan(usize, 6);
            while (f < flips) : (f += 1) hdr[rand.uintLessThan(usize, 128)] = rand.int(u8);
        }
        snapshot.fuzzHeader(&hdr);
    }
}

// --- PL031 RTC MMIO --------------------------------------------------------
//
// The guest drives arbitrary MMIO accesses to the RTC: any offset, any width. The
// register decode must never OOB or panic (the data register is a bounded read of host
// time; writes only store). Interpret the fuzz bytes as a stream of {offset, len, data}.

fn feedPl031(bytes: []const u8) void {
    var rtc = pl031.Pl031{};
    const dev = rtc.device(0x0901_0000);
    var i: usize = 0;
    while (i + 2 <= bytes.len) {
        const off: u64 = (@as(u64, bytes[i]) | (@as(u64, bytes[i + 1]) << 8)) & 0xFFF; // in-page offset
        i += 2;
        const len: usize = @min(1 + (@as(usize, if (i < bytes.len) bytes[i] else 0) % 8), bytes.len - i + 1);
        if (i < bytes.len) i += 1;
        var buf: [8]u8 = undefined;
        const take = @min(len, buf.len);
        var j: usize = 0;
        while (j < take and i < bytes.len) : (j += 1) {
            buf[j] = bytes[i];
            i += 1;
        }
        if (off & 1 == 0) {
            dev.write_fn(dev.ptr, off, buf[0..take]);
        } else {
            dev.read_fn(dev.ptr, off, buf[0..take]);
            std.mem.doNotOptimizeAway(buf);
        }
    }
}

test "pl031 mmio survives arbitrary guest accesses" {
    var prng = fuzzPrng(0x9013_1FDC);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        var buf: [64]u8 = undefined;
        const n = 1 + rand.uintLessThan(usize, buf.len);
        rand.bytes(buf[0..n]);
        feedPl031(buf[0..n]);
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
    var prng = fuzzPrng(0x4E700FF);
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
    var prng = fuzzPrng(0x69_70_75);
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
    var prng = fuzzPrng(0x6_C0_FF_EE);
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

    var prng = fuzzPrng(0xC0FFEE_11);
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
    var prng = fuzzPrng(0xBA12_EAD);
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
    var prng = fuzzPrng(0xE1F_F022);
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
    var prng = fuzzPrng(0x5117_F0FF);
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
    var prng = fuzzPrng(0x14_BADD_11);
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

// --- virtio-blk device -----------------------------------------------------
//
// The block device serves guest requests (a header with type + sector, then data
// segments, then a status byte) against a flat backing store, doing sector*512
// arithmetic on a guest-controlled sector. The disk sits between canary guards, so the
// invariant is direct: blk must NEVER write outside `disk`, whatever the request, and it
// always leaves a defined status code.

fn putDesc(ram: []u8, idx: usize, addr: u64, len: u32, flags: u16, next: u16) void {
    const a = idx * 16;
    std.mem.writeInt(u64, ram[a..][0..8], addr, .little);
    std.mem.writeInt(u32, ram[a + 8 ..][0..4], len, .little);
    std.mem.writeInt(u16, ram[a + 12 ..][0..2], flags, .little);
    std.mem.writeInt(u16, ram[a + 14 ..][0..2], next, .little);
}

fn fbyte(bytes: []const u8, i: usize) u8 {
    return if (i < bytes.len) bytes[i] else 0;
}

fn feedBlk(bytes: []const u8) void {
    const GUARD = 64;
    const DISK = 2048;
    var backing = [_]u8{0xC5} ** (GUARD + DISK + GUARD); // 0xC5 canary either side of the disk
    const disk = backing[GUARD..][0..DISK];
    @memset(disk, 0);
    var ram = [_]u8{0} ** 4096;

    // Request shape from the fuzz bytes: type (biased to the real opcodes), a sector
    // biased toward the u64-overflow boundary, and two data-segment lengths.
    const TYPES = [_]u32{ 0, 1, 4, 8, 3, 0xdead_beef }; // IN/OUT/FLUSH/GET_ID/unsupported/garbage
    const rtype = TYPES[fbyte(bytes, 0) % TYPES.len];
    const sector: u64 = switch (fbyte(bytes, 1) & 3) {
        0 => std.math.maxInt(u64), // sector*512 overflows u64: must reject, not wrap
        1 => std.math.maxInt(u64) / 512, // just under the overflow boundary
        2 => @as(u64, fbyte(bytes, 2)) << 3,
        else => fbyte(bytes, 2),
    };
    const l0: u32 = @as(u32, fbyte(bytes, 3)) * 2; // 0..510, fits the 512-byte data buffer
    const l1: u32 = @as(u32, fbyte(bytes, 4)) * 2;

    var b = blk.Blk{ .disk = disk };
    var dev = virtio.Device.init(b.backend(), .{ .bytes = &ram, .base = 0 });
    dev.barWrite(0x16, 2, 0); // queue_select 0
    dev.barWrite(0x18, 2, 8); // queue_size
    dev.barWrite(0x20, 4, 0x000); // desc
    dev.barWrite(0x28, 4, 0x100); // avail
    dev.barWrite(0x30, 4, 0x200); // used
    dev.barWrite(0x1c, 2, 1); // enable

    // header(16) -> data0 -> data1 -> status(1)
    putDesc(&ram, 0, 0x400, 16, virtq.DESC_F_NEXT, 1);
    putDesc(&ram, 1, 0x600, l0, virtq.DESC_F_NEXT | virtq.DESC_F_WRITE, 2);
    putDesc(&ram, 2, 0x800, l1, virtq.DESC_F_NEXT | virtq.DESC_F_WRITE, 3);
    putDesc(&ram, 3, 0xA00, 1, virtq.DESC_F_WRITE, 0);
    std.mem.writeInt(u32, ram[0x400..][0..4], rtype, .little);
    std.mem.writeInt(u64, ram[0x408..][0..8], sector, .little);
    for (ram[0x600..0xA00], 0..) |*d, i| d.* = fbyte(bytes, 8 + i); // T_OUT payload from the fuzz bytes
    std.mem.writeInt(u16, ram[0x102..][0..2], 1, .little); // avail.idx
    std.mem.writeInt(u16, ram[0x104..][0..2], 0, .little); // ring[0] = head 0

    dev.barWrite(0x2000, 4, 0); // kick

    // Invariants: a defined status code, and no write escaped the disk into the canary.
    std.debug.assert(ram[0xA00] <= 2); // S_OK / S_IOERR / S_UNSUPP
    for (backing[0..GUARD]) |c| std.debug.assert(c == 0xC5);
    for (backing[GUARD + DISK ..]) |c| std.debug.assert(c == 0xC5);
    std.mem.doNotOptimizeAway(dev.isr);
}

test "virtio-blk survives hostile requests and never writes past the disk" {
    var prng = fuzzPrng(0xB10C_C0DE);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 6000) : (i += 1) {
        var buf: [1040]u8 = undefined; // header params + up to ~1 KiB of OUT payload
        const n = 1 + rand.uintLessThan(usize, buf.len);
        rand.bytes(buf[0..n]);
        feedBlk(buf[0..n]);
    }
}

// --- fw_cfg (guest-streamed selector/offset) -------------------------------
//
// The guest picks an item with the selector port and streams its bytes from the data
// port; the offset increments per read and must stay bounded by the item length (a read
// past the end returns 0, never OOB). Register a couple of files so the file + directory
// paths run too.

fn feedFwCfg(bytes: []const u8) void {
    var fw = fw_cfg.FwCfg{};
    fw.addFile("etc/a", "PAYLOAD-A") catch {};
    fw.addFile("etc/table-loader", "XYZ") catch {};
    const dev = fw.device();
    const KEYS = [_]u16{ 0x0000, 0x0001, 0x0019, 0x0020, 0x0021, 0xffff }; // sig/id/dir/files/absent
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        dev.out_fn(dev.ptr, 0x510, 2, KEYS[bytes[i] % KEYS.len]); // select an item
        const reads: usize = fbyte(bytes, i + 1); // 0..255 streamed reads: pushes offset past small items
        var r: usize = 0;
        while (r < reads) : (r += 1) {
            const v = dev.in_fn(dev.ptr, 0x511, 1);
            std.debug.assert(v <= 0xff); // the data register is a single byte
            std.mem.doNotOptimizeAway(v);
        }
    }
    std.debug.assert(fw.dir_len <= fw.dir.len); // the directory never overruns its buffer
}

test "fw_cfg survives arbitrary selector/stream sequences" {
    var prng = fuzzPrng(0xF00_C0FE);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 8000) : (i += 1) {
        var buf: [64]u8 = undefined;
        const n = 1 + rand.uintLessThan(usize, buf.len);
        rand.bytes(buf[0..n]);
        feedFwCfg(buf[0..n]);
    }
}

// --- control-plane relay scanner (exit-trailer rewrite) --------------------
//
// The relay scans the guest agent's reply stream for the 0x1e<exit>\n trailer and clamps
// a non-canonical exit to 255 (the R2b / exit-clamp audit code). It is stateful across
// chunk boundaries, so feed the bytes in small guest-derived chunks. Two invariants: the
// output never exceeds outBound(chunk.len) (a wrong bound would OOB out[]), and every
// emitted trailer carries a canonical exit (<= 255).

fn checkClamped(out: []const u8) void {
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        if (out[i] != 0x1e) continue; // OUT_DELIM (ASCII RS): starts an emitted trailer
        var j = i + 1;
        while (j < out.len and out[j] != '\n') : (j += 1) {}
        if (j < out.len) { // a complete trailer: digits then '\n'
            const v = std.fmt.parseInt(u32, out[i + 1 .. j], 10) catch {
                std.debug.assert(false); // an emitted trailer is always numeric
                return;
            };
            std.debug.assert(v <= 255); // ... and always clamped in range
            i = j;
        }
    }
}

fn feedRelay(bytes: []const u8) void {
    var sc = control.RelayScanner{};
    var i: usize = 0;
    while (i < bytes.len) {
        const step = 1 + (fbyte(bytes, i) % 7); // chunk 1..7, from the data
        const end = @min(i + step, bytes.len);
        const chunk = bytes[i..end];
        var out: [control.RelayScanner.outBound(7)]u8 = undefined; // fits the max chunk
        const n = sc.scan(chunk, &out);
        std.debug.assert(n <= control.RelayScanner.outBound(chunk.len)); // the output bound holds
        checkClamped(out[0..n]);
        i = end;
    }
}

test "relay scanner survives hostile agent output (bound + exit clamp hold)" {
    // Bias toward the trailer delimiter and digits so the trailer state machine is driven
    // deep (held trailers, overlong/garbage exits, split across chunks), not just copied.
    const alphabet = [_]u8{ 0x1e, '\n', '0', '9', '2', '5', '6', '-', 'A', 0x1f };
    var prng = fuzzPrng(0x2E_11_A5);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 8000) : (i += 1) {
        var buf: [128]u8 = undefined;
        const n = rand.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*b| b.* = if (rand.boolean()) alphabet[rand.uintLessThan(usize, alphabet.len)] else rand.int(u8);
        feedRelay(buf[0..n]);
    }
}

// --- coverage-guided fuzz entry points (zig build test --fuzz) -------------
// The tests above are fixed-seed smoke (always-on, reproducible). These mirror them
// through std.testing.fuzz, so `zig build fuzz` (-> test --fuzz) drives the same
// parsers coverage-guided. Under a plain `zig build test` they run a quick smoke pass.
test "fuzz: vt parser" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const n = smith.slice(&buf);
            feedParser(buf[0..n]);
        }
    }.one, .{});
}

test "fuzz: screen grid" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var s = Screen.init(std.testing.allocator, 24, 80) catch return;
            defer s.deinit();
            var buf: [256]u8 = undefined;
            const n = smith.slice(&buf);
            s.write(buf[0..n]);
        }
    }.one, .{});
}

test "fuzz: virtqueue" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var ram: [1024]u8 = undefined;
            smith.bytes(&ram);
            feedVirtq(&ram);
        }
    }.one, .{});
}

test "fuzz: vsock engine" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const n = smith.slice(&buf);
            var vs = vsock.Vsock{ .guest_cid = 3 };
            _ = vs.listen(1024);
            feedVsock(&vs, buf[0..n]);
        }
    }.one, .{});
}

test "fuzz: vsock snapshot state" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            // Fill the ENTIRE engine State with attacker bytes (the whole on-disk image),
            // then run it through the validate -> import -> drain contract.
            var st: vsock.Vsock.State = undefined;
            smith.bytes(std.mem.asBytes(&st));
            feedVsockState(&st);
        }
    }.one, .{});
}

// The snapshot header parser: a corrupt/hostile restore file must never crash the
// validator nor pass an out-of-bounds field to the section-offset arithmetic.
test "fuzz: snapshot header" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var hdr: [128]u8 = undefined;
            smith.bytes(&hdr);
            snapshot.fuzzHeader(&hdr);
        }
    }.one, .{});
}

// PL031 RTC MMIO: the guest can issue any-offset/any-width accesses; the decode must
// stay memory-safe.
test "fuzz: pl031 rtc mmio" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [128]u8 = undefined;
            const n = smith.slice(&buf);
            feedPl031(buf[0..n]);
        }
    }.one, .{});
}

// The data-plane bridge (park-concurrency 3b, step 2b): a hostile/misbehaving guest
// server drives the vsock events that reach the bridge. Fuzz its event + lifecycle
// state machine (register/connected/recv/reset/teardown) for memory-safety + invariants.
test "fuzz: data-plane bridge" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [128]u8 = undefined;
            const n = smith.slice(&buf);
            control.fuzzBridge(buf[0..n]);
        }
    }.one, .{});
}

test "fuzz: virtio-net" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var ram: [4096]u8 = undefined;
            smith.bytes(&ram);
            var frame: [256]u8 = undefined;
            const n = smith.slice(&frame);
            feedNet(&ram, frame[0..n]);
        }
    }.one, .{});
}

test "fuzz: virtio-gpu command" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var cmd: [512]u8 = undefined;
            const n = smith.slice(&cmd);
            var ram: [4096]u8 = undefined;
            feedGpuCmd(&ram, cmd[0..n]);
        }
    }.one, .{});
}

test "fuzz: slirp guest frame" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var frame: [256]u8 = undefined;
            const n = smith.slice(&frame);
            var s = slirp.Slirp{};
            _ = s.addBlock("0.0.0.0/0"); // deny-all -> no host sockets
            s.out_fn = slirpSink;
            s.out_ctx = &s;
            s.onGuestFrame(frame[0..n]);
        }
    }.one, .{});
}

test "fuzz: ELF/PVH loader" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var img: [512]u8 = undefined;
            const n = smith.slice(&img);
            var sink = ElfSink{};
            _ = elf.loadPvh(img[0..n], &sink) catch {};
        }
    }.one, .{});
}

// virtio-blk request path: guest header (type/sector) + data segments + status, with
// sector*512 arithmetic. The canary-guarded disk asserts no write ever escapes it.
test "fuzz: virtio-blk" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [1040]u8 = undefined;
            const n = smith.slice(&buf);
            feedBlk(buf[0..n]);
        }
    }.one, .{});
}

// fw_cfg: guest-chosen selector + an unbounded stream of data reads; the per-read offset
// must stay bounded by the item length and the directory must never overrun its buffer.
test "fuzz: fw_cfg" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            const n = smith.slice(&buf);
            feedFwCfg(buf[0..n]);
        }
    }.one, .{});
}

// The relay exit-trailer scanner (R2b / exit-clamp): stateful over guest output, fed in
// chunks. The output bound (outBound) and the exit clamp (<= 255) must both hold.
test "fuzz: relay scanner" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const n = smith.slice(&buf);
            feedRelay(buf[0..n]);
        }
    }.one, .{});
}
