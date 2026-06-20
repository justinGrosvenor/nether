//! Deterministic fuzz-smoke for Nether's guest-facing parsers.
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
const virtq = @import("virtq.zig");
const virtio = @import("virtio.zig");
const vsock = @import("virtio_vsock.zig");
const net = @import("virtio_net.zig");

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
