//! Unified event journal (the "observe" pillar): one sequenced, chronological feed
//! of everything notable a sandbox did - commands run, network destinations reached,
//! and lifecycle transitions (boot/ready/shutdown) - that the platform polls with a
//! monotonic cursor. `__netlog__`/`__cmdlog__` are the per-domain detail views; this
//! is the single timeline the platform follows incrementally ("events since seq N")
//! and the only place lifecycle events are recorded.
//!
//! Every record point (slirp.recordFlow, control.commitPending, lifecycle) calls
//! `emit` from its own thread, so the ring is guarded by a leaf lock.

const std = @import("std");
const Lock = @import("lock.zig").Lock;
const nowMs = @import("hostutil.zig").nowMs;

const CAP = 512; // retained events (older ones age out of the ring)
const TEXT_MAX = 160;

pub const Kind = enum(u8) {
    cmd, // a shell command + its exit code
    net, // an egress connection/flow + the firewall verdict
    life, // a lifecycle transition

    fn tag(self: Kind) []const u8 {
        return switch (self) {
            .cmd => "CMD",
            .net => "NET",
            .life => "LIFE",
        };
    }
};

const Event = struct {
    seq: u64 = 0,
    ms: i64 = 0,
    kind: Kind = .life,
    text: [TEXT_MAX]u8 = undefined,
    len: usize = 0,
};

pub const Journal = struct {
    lock: Lock = .{},
    ring: [CAP]Event = [_]Event{.{}} ** CAP,
    head: usize = 0, // next write slot
    seq: u64 = 0, // last assigned sequence number (monotonic, lifetime)

    /// Append one event. `text` is truncated to TEXT_MAX. Thread-safe.
    pub fn emit(self: *Journal, kind: Kind, text: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.seq += 1;
        const n = @min(text.len, TEXT_MAX);
        var e = Event{ .seq = self.seq, .ms = nowMs(), .kind = kind, .len = n };
        @memcpy(e.text[0..n], text[0..n]);
        self.ring[self.head] = e;
        self.head = (self.head + 1) % CAP;
    }

    /// Serialize events with `seq > after` (oldest-first) into `out`:
    ///   "EVENTS <current-seq>\n"  then  "<seq> <ms> <KIND> <text>\n" per event.
    /// The header's current-seq is the cursor the client passes as `after` next time.
    /// If `after` lags more than CAP behind, the gap (events that aged out) is implied
    /// by the seq jump; the client can detect it from non-contiguous seq numbers.
    pub fn since(self: *Journal, out: []u8, after: u64) usize {
        self.lock.lock();
        defer self.lock.unlock();
        var n: usize = (std.fmt.bufPrint(out, "EVENTS {d}\n", .{self.seq}) catch return 0).len;
        const retained: usize = if (self.seq < CAP) @intCast(self.seq) else CAP;
        const start = if (self.seq < CAP) 0 else self.head; // oldest retained slot
        var i: usize = 0;
        while (i < retained) : (i += 1) {
            const e = self.ring[(start + i) % CAP];
            if (e.seq <= after) continue;
            const line = std.fmt.bufPrint(out[n..], "{d} {d} {s} {s}\n", .{ e.seq, e.ms, e.kind.tag(), e.text[0..e.len] }) catch break;
            n += line.len;
        }
        return n;
    }
};

// --- tests -----------------------------------------------------------------
const testing = std.testing;

test "journal assigns monotonic seq and replays events after a cursor" {
    var j = Journal{};
    j.emit(.life, "boot");
    j.emit(.cmd, "exit=0 echo hi");
    j.emit(.net, "TCP 1.1.1.1:443 ALLOW");

    var buf: [4096]u8 = undefined;
    const all = buf[0..j.since(&buf, 0)];
    try testing.expect(std.mem.startsWith(u8, all, "EVENTS 3\n"));
    try testing.expect(std.mem.indexOf(u8, all, "1 ") != null); // seq 1 present
    try testing.expect(std.mem.indexOf(u8, all, "LIFE boot\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "CMD exit=0 echo hi\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "NET TCP 1.1.1.1:443 ALLOW\n") != null);

    // Incremental: only events after seq 2.
    const tail = buf[0..j.since(&buf, 2)];
    try testing.expect(std.mem.startsWith(u8, tail, "EVENTS 3\n"));
    try testing.expect(std.mem.indexOf(u8, tail, "NET TCP 1.1.1.1:443 ALLOW\n") != null);
    try testing.expect(std.mem.indexOf(u8, tail, "LIFE boot\n") == null); // already seen
    try testing.expect(std.mem.indexOf(u8, tail, "CMD ") == null);

    // A cursor at the head yields no events (just the header).
    const none = buf[0..j.since(&buf, 3)];
    try testing.expectEqualStrings("EVENTS 3\n", none);
}

test "journal ring ages out old events but keeps the lifetime seq" {
    var j = Journal{};
    var i: u32 = 0;
    while (i < CAP + 10) : (i += 1) {
        var nb: [32]u8 = undefined;
        j.emit(.cmd, std.fmt.bufPrint(&nb, "exit=0 cmd{d}", .{i}) catch unreachable);
    }
    var buf: [65536]u8 = undefined;
    const out = buf[0..j.since(&buf, 0)];
    var hb: [32]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hb, "EVENTS {d}\n", .{CAP + 10}) catch unreachable;
    try testing.expect(std.mem.startsWith(u8, out, hdr)); // lifetime seq survives the wrap
    try testing.expect(std.mem.indexOf(u8, out, " cmd0\n") == null); // earliest aged out
    try testing.expect(std.mem.indexOf(u8, out, " cmd521\n") != null); // newest retained
}
