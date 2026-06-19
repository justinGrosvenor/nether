//! Minimal OSC (Operating System Command) parser.
//!
//! VENDORED-REPLACEMENT: this is NOT Ghostty's osc.zig. Ghostty's full OSC
//! parser drags in kitty graphics colors, the C-ABI `lib` helpers, and OSC
//! sub-parsers (clipboard, hyperlinks, color palette). For Nether's serial
//! console we only need the common title commands, so this is a small,
//! zero-alloc replacement that satisfies exactly the interface Parser.zig
//! calls: init/deinit/reset/next/end. See PORTING.md.
//!
//! Bytes between the OSC introducer and its terminator are buffered into a
//! fixed-size array (overflow is dropped). On `end`, the leading numeric code
//! up to the first ';' selects the command. Returned slices point into the
//! internal buffer and are valid only until the next `reset`.

const std = @import("std");

/// The subset of OSC commands Nether interprets. Everything else is surfaced
/// as `raw` so a caller can handle or ignore it.
pub const Command = union(enum) {
    /// OSC 0 or 2: set the window title.
    change_window_title: []const u8,
    /// OSC 1: set the icon name.
    change_icon_title: []const u8,
    /// Any other OSC string, code included, uninterpreted.
    raw: []const u8,
};

pub const Parser = struct {
    /// Present only for API compatibility with Ghostty's parser (some callers
    /// assign it). This implementation never allocates.
    alloc: ?std.mem.Allocator = null,

    buf: [max_len]u8 = undefined,
    len: usize = 0,
    command: Command = .{ .raw = "" },

    /// OSC strings beyond this are truncated. Titles and the like are short;
    /// this is generous headroom without a heap.
    const max_len = 1024;

    pub fn init(alloc: ?std.mem.Allocator) Parser {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Parser) void {
        _ = self;
    }

    pub fn reset(self: *Parser) void {
        self.len = 0;
    }

    /// Buffer one OSC byte. Overflow bytes are dropped.
    pub fn next(self: *Parser, c: u8) void {
        if (self.len >= max_len) return;
        self.buf[self.len] = c;
        self.len += 1;
    }

    /// Finalize the buffered string into a Command. `c` is the terminator byte
    /// (BEL or the ST final), which is not part of the payload. Returns null for
    /// an empty sequence. The returned pointer is valid until the next `reset`.
    pub fn end(self: *Parser, c: u8) ?*Command {
        _ = c;
        const s = self.buf[0..self.len];
        if (s.len == 0) return null;

        // Split on the first ';': everything before is the numeric code.
        const sep = std.mem.indexOfScalar(u8, s, ';') orelse {
            self.command = .{ .raw = s };
            return &self.command;
        };
        const code = s[0..sep];
        const body = s[sep + 1 ..];

        self.command = if (std.mem.eql(u8, code, "0") or std.mem.eql(u8, code, "2"))
            .{ .change_window_title = body }
        else if (std.mem.eql(u8, code, "1"))
            .{ .change_icon_title = body }
        else
            .{ .raw = s };
        return &self.command;
    }
};

test "OSC 0 sets window title" {
    var p = Parser.init(null);
    for ("0;hello") |c| p.next(c);
    const cmd = p.end(0x07).?;
    try std.testing.expect(cmd.* == .change_window_title);
    try std.testing.expectEqualStrings("hello", cmd.change_window_title);
}

test "OSC 1 sets icon title" {
    var p = Parser.init(null);
    for ("1;icon") |c| p.next(c);
    const cmd = p.end(0x07).?;
    try std.testing.expect(cmd.* == .change_icon_title);
    try std.testing.expectEqualStrings("icon", cmd.change_icon_title);
}

test "unknown OSC code surfaces as raw" {
    var p = Parser.init(null);
    for ("52;c;data") |c| p.next(c);
    const cmd = p.end(0x07).?;
    try std.testing.expect(cmd.* == .raw);
    try std.testing.expectEqualStrings("52;c;data", cmd.raw);
}

test "empty OSC yields no command" {
    var p = Parser.init(null);
    try std.testing.expect(p.end(0x07) == null);
}
