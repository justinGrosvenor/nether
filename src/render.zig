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
const Screen = @import("vt/Screen.zig");
const Lock = @import("lock.zig").Lock;

pub const Render = struct {
    screen: Screen,
    lock: Lock = .{}, // the agent RX thread feeds; a control thread snapshots
    in_trailer: bool = false, // mid 0x1e<exit>\n framing trailer (skipped)

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
