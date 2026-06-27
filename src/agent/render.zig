//! The render pillar: a server-side terminal model of the agent's session. The
//! agent's command output is teed through a VT `Screen` (the same parser/grid the
//! serial console uses), so the platform can fetch a rendered snapshot of what the
//! sandbox's terminal currently shows - to display, stream, or store as the visible
//! artifact of an untrusted agent's work - without the guest cooperating.
//!
//! Input is the agent's reply stream, which interleaves command output with the
//! protocol's `0x1e<exit-code>\n` framing trailers; `feed` strips those so only the
//! terminal output reaches the grid.

const std = @import("std");
const Screen = @import("../vt/Screen.zig");
const Lock = @import("../common/lock.zig").Lock;

pub const Render = struct {
    screen: Screen,
    lock: Lock = .{}, // the agent RX thread feeds; a control thread snapshots
    in_trailer: bool = false, // mid 0x1e<exit>\n framing trailer (skipped)
    // Streaming diff state: a hash of each live row as last emitted, so `diff` can
    // send only the rows that changed. `primed` is false until the first diff (which
    // emits the whole current screen). Sized past the 200-row config clamp.
    row_hash: [256]u64 = [_]u64{0} ** 256,
    primed: bool = false,

    pub fn init(alloc: std.mem.Allocator, rows: u16, cols: u16) !Render {
        return .{ .screen = try Screen.init(alloc, rows, cols) };
    }

    pub fn deinit(self: *Render) void {
        self.screen.deinit();
    }

    /// Tee agent reply bytes into the grid, dropping the `0x1e<exit>\n` trailers so
    /// the screen reflects only terminal output.
    pub fn feed(self: *Render, bytes: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        var i: usize = 0;
        while (i < bytes.len) {
            if (self.in_trailer) {
                while (i < bytes.len and bytes[i] != '\n') i += 1;
                if (i < bytes.len) { // consumed the trailing newline
                    self.in_trailer = false;
                    i += 1;
                }
                continue;
            }
            const start = i;
            while (i < bytes.len and bytes[i] != 0x1e and bytes[i] != '\n') i += 1;
            if (i > start) self.screen.write(bytes[start..i]);
            if (i < bytes.len) {
                if (bytes[i] == '\n') {
                    // Command output comes off a pipe (bare LF, no CR), so map LF to
                    // CR+LF the way a cooked tty's ONLCR does - otherwise the grid
                    // staircases (each line keeps the prior column).
                    self.screen.write("\r\n");
                    i += 1;
                } else { // 0x1e record separator: skip the <exit>\n framing trailer
                    self.in_trailer = true;
                    i += 1;
                }
            }
        }
    }

    /// Force the next `diff` to re-emit the whole screen (call when a fresh control
    /// client connects so it gets a full picture before deltas).
    pub fn resetDiff(self: *Render) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.primed = false;
    }

    /// Streaming delta: emit only the LIVE rows (the fixed rows x cols grid, not
    /// scrollback) that changed since the last call, so the platform can follow the
    /// screen cheaply. Wire format:
    ///   SCREEN <rows>x<cols>\n
    ///   <row-index> <text>\n      (one per changed row; text may be empty = cleared)
    ///   \n                        (blank line terminates)
    /// The first call after init/resetDiff emits every non-empty row (the full
    /// screen). Returns the bytes written into `out`.
    pub fn diff(self: *Render, out: []u8) usize {
        self.lock.lock();
        defer self.lock.unlock();
        var n: usize = 0;
        const rows = self.screen.rows;
        const sb = self.screen.scrollbackLen();
        n += (std.fmt.bufPrint(out[n..], "SCREEN {d}x{d}\n", .{ rows, self.screen.cols }) catch return n).len;
        var rbuf: [4096]u8 = undefined;
        var j: u16 = 0;
        while (j < rows) : (j += 1) {
            const line = std.mem.trimEnd(u8, self.screen.viewRow(sb + j, &rbuf), " ");
            const h = std.hash.Wyhash.hash(0, line);
            const changed = if (self.primed) h != self.row_hash[j] else line.len > 0;
            self.row_hash[j] = h;
            if (changed) {
                const w = std.fmt.bufPrint(out[n..], "{d} {s}\n", .{ j, line }) catch break;
                n += w.len;
            }
        }
        self.primed = true;
        if (n < out.len) { // terminating blank line
            out[n] = '\n';
            n += 1;
        }
        return n;
    }

    /// Render the non-empty rows of the current view (scrollback + live screen) into
    /// `out` as newline-joined lines with trailing spaces trimmed. Returns the bytes
    /// written. This is what the `__screen__` control command returns.
    pub fn snapshot(self: *Render, out: []u8) usize {
        self.lock.lock();
        defer self.lock.unlock();
        var n: usize = 0;
        var rbuf: [4096]u8 = undefined;
        const total = self.screen.viewRows();
        var i: usize = 0;
        while (i < total) : (i += 1) {
            const line = std.mem.trimEnd(u8, self.screen.viewRow(i, &rbuf), " ");
            if (line.len == 0) continue; // skip blank rows
            if (n + line.len + 1 > out.len) break;
            @memcpy(out[n..][0..line.len], line);
            n += line.len;
            out[n] = '\n';
            n += 1;
        }
        return n;
    }
};

test "feed strips 0x1e<exit> trailers and renders output" {
    var r = try Render.init(std.testing.allocator, 8, 40);
    defer r.deinit();
    // Two "commands": output then a 0x1e<code>\n trailer that must not appear.
    r.feed("hello\n");
    r.feed("\x1e0\n");
    r.feed("world\x1e1\n");
    var buf: [256]u8 = undefined;
    const out = buf[0..r.snapshot(&buf)];
    try std.testing.expect(std.mem.indexOf(u8, out, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "world") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, out, 0x1e) == null); // no RS
    try std.testing.expect(std.mem.indexOf(u8, out, "world1") == null); // trailer stripped
}

test "diff emits the full screen first, then only changed rows" {
    var r = try Render.init(std.testing.allocator, 4, 20);
    defer r.deinit();
    r.feed("line-a\n"); // row 0
    r.feed("line-b\n"); // row 1
    var buf: [512]u8 = undefined;
    const d1 = buf[0..r.diff(&buf)]; // first diff = full screen
    try std.testing.expect(std.mem.indexOf(u8, d1, "0 line-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, d1, "1 line-b") != null);
    const d2 = buf[0..r.diff(&buf)]; // nothing changed -> no row lines
    try std.testing.expect(std.mem.indexOf(u8, d2, "line-a") == null);
    try std.testing.expect(std.mem.indexOf(u8, d2, "line-b") == null);
    r.feed("line-c\n"); // row 2 changes
    const d3 = buf[0..r.diff(&buf)];
    try std.testing.expect(std.mem.indexOf(u8, d3, "2 line-c") != null);
    try std.testing.expect(std.mem.indexOf(u8, d3, "line-a") == null); // unchanged row not re-sent
}

test "feed handles a trailer split across two chunks" {
    var r = try Render.init(std.testing.allocator, 4, 20);
    defer r.deinit();
    r.feed("abc\x1e12"); // output + start of trailer (digits, no newline yet)
    r.feed("3\n"); // rest of the trailer
    r.feed("def\n");
    var buf: [128]u8 = undefined;
    const out = buf[0..r.snapshot(&buf)];
    try std.testing.expect(std.mem.indexOf(u8, out, "abc") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "def") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "123") == null); // exit code not rendered
}
