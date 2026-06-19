//! Terminal screen grid: the consumer of the VT parser.
//!
//! NETHER-AUTHORED (not vendored, cf. Parser.zig). This is the "own the grid"
//! half of the parser-vendor strategy: a small screen model sized to a serial
//! console, driven by the vendored parser's actions.
//!
//! State is deliberately fixed-size and pointer-free (a flat cell buffer plus a
//! cursor and a pen), so it is serializable by construction. That is the
//! pattern-6 discipline snapshot-fork needs (see docs/references/ghostty-
//! patterns.md): a screen snapshot is just the dims, cursor, pen, and cell
//! bytes.
//!
//! Scope (v1): printable ASCII, deferred autowrap, the C0 controls and the
//! CSI/SGR/ED/EL/cursor sequences a shell and getty emit. Deliberately NOT yet
//! handled (grow as needed): scrollback, the alternate screen, scroll regions
//! (DECSTBM), and UTF-8 multibyte / wide characters. UTF-8 needs a decoder
//! ahead of the byte parser; until then high bytes are not rendered. Cells store
//! a u21 codepoint so that addition is forward-compatible.

const Screen = @This();

const std = @import("std");
const Parser = @import("Parser.zig");

/// A cell color: terminal default, a 256-color palette index, or direct RGB.
pub const Color = union(enum) {
    default,
    palette: u8,
    rgb: struct { r: u8, g: u8, b: u8 },
};

/// SGR attribute flags.
pub const Attrs = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    hidden: bool = false,
    strike: bool = false,
};

/// The rendition applied to a cell.
pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},
};

/// One screen cell: a codepoint and its style. No pointers, so a row or the
/// whole grid serializes by copy.
pub const Cell = struct {
    cp: u21 = ' ',
    style: Style = .{},
};

pub const Cursor = struct {
    row: u16 = 0,
    col: u16 = 0,
};

alloc: std.mem.Allocator,
rows: u16,
cols: u16,
cells: []Cell, // rows*cols, row-major
cursor: Cursor = .{},
pen: Style = .{}, // style applied to newly printed cells
/// DEC deferred autowrap: set after printing in the last column. The wrap
/// happens on the next printable, so a glyph in the last column does not scroll
/// prematurely.
pending_wrap: bool = false,
/// Window title from OSC 0/2, if any.
title_buf: [256]u8 = undefined,
title_len: usize = 0,

parser: Parser,

pub fn init(alloc: std.mem.Allocator, rows: u16, cols: u16) !Screen {
    std.debug.assert(rows > 0 and cols > 0);
    const cells = try alloc.alloc(Cell, @as(usize, rows) * cols);
    @memset(cells, .{});
    return .{
        .alloc = alloc,
        .rows = rows,
        .cols = cols,
        .cells = cells,
        .parser = Parser.init(),
    };
}

pub fn deinit(self: *Screen) void {
    self.parser.deinit();
    self.alloc.free(self.cells);
}

fn idx(self: *const Screen, row: u16, col: u16) usize {
    return @as(usize, row) * self.cols + col;
}

/// The cell at (row, col), or a blank cell if out of range.
pub fn cellAt(self: *const Screen, row: u16, col: u16) Cell {
    if (row >= self.rows or col >= self.cols) return .{};
    return self.cells[self.idx(row, col)];
}

/// Encode a row's codepoints as UTF-8 into `buf` (which must be >= cols*4) and
/// return the slice. Trailing blanks are included; callers that want a trimmed
/// line can std.mem.trimRight the result. Handy for golden tests and rendering.
pub fn rowText(self: *const Screen, row: u16, buf: []u8) []const u8 {
    var n: usize = 0;
    var c: u16 = 0;
    while (c < self.cols) : (c += 1) {
        const cp = self.cellAt(row, c).cp;
        n += std.unicode.utf8Encode(cp, buf[n..]) catch 0;
    }
    return buf[0..n];
}

/// Feed guest output bytes through the parser and apply the resulting actions.
pub fn write(self: *Screen, bytes: []const u8) void {
    for (bytes) |b| {
        const actions = self.parser.next(b);
        for (actions) |maybe| if (maybe) |a| self.apply(a);
    }
}

fn apply(self: *Screen, action: Parser.Action) void {
    switch (action) {
        .print => |cp| self.putChar(cp),
        .execute => |b| self.control(b),
        .csi_dispatch => |c| self.csi(c),
        .esc_dispatch => |esc| self.escape(esc),
        .osc_dispatch => |cmd| self.osc(cmd),
        // DCS and APC are surfaced by the parser but not interpreted here.
        .dcs_hook, .dcs_put, .dcs_unhook => {},
        .apc_start, .apc_put, .apc_end => {},
    }
}

// --- printing & scrolling --------------------------------------------------

fn putChar(self: *Screen, cp: u21) void {
    if (self.pending_wrap) {
        self.cursor.col = 0;
        self.lineFeed();
        self.pending_wrap = false;
    }
    self.cells[self.idx(self.cursor.row, self.cursor.col)] = .{ .cp = cp, .style = self.pen };
    if (self.cursor.col + 1 >= self.cols) {
        self.pending_wrap = true; // defer the wrap until the next printable
    } else {
        self.cursor.col += 1;
    }
}

fn control(self: *Screen, b: u8) void {
    switch (b) {
        0x0a, 0x0b, 0x0c => self.lineFeed(), // LF / VT / FF
        0x0d => { // CR
            self.cursor.col = 0;
            self.pending_wrap = false;
        },
        0x08 => { // BS
            if (self.cursor.col > 0) self.cursor.col -= 1;
            self.pending_wrap = false;
        },
        0x09 => self.tab(), // HT
        else => {}, // BEL and the rest: ignored
    }
}

fn lineFeed(self: *Screen) void {
    self.pending_wrap = false;
    if (self.cursor.row + 1 >= self.rows) self.scrollUp() else self.cursor.row += 1;
}

fn tab(self: *Screen) void {
    // Fixed tab stops every 8 columns.
    const next = (self.cursor.col / 8 + 1) * 8;
    self.cursor.col = @min(next, self.cols - 1);
    self.pending_wrap = false;
}

fn scrollUp(self: *Screen) void {
    // Move every row up by one and blank the last row.
    const stride = self.cols;
    std.mem.copyForwards(Cell, self.cells[0 .. self.cells.len - stride], self.cells[stride..]);
    @memset(self.cells[self.cells.len - stride ..], .{});
}

// --- escape / CSI ----------------------------------------------------------

fn escape(self: *Screen, esc: Parser.Action.ESC) void {
    // Only RIS (full reset) is handled; charset selection and the rest are
    // ignored for a serial console.
    if (esc.intermediates.len == 0 and esc.final == 'c') self.reset();
}

fn reset(self: *Screen) void {
    @memset(self.cells, .{});
    self.cursor = .{};
    self.pen = .{};
    self.pending_wrap = false;
}

fn csi(self: *Screen, c: Parser.Action.CSI) void {
    // Private sequences (e.g. DEC modes "?25h") carry intermediates; we do not
    // interpret them. The common cursor/erase/SGR commands have none.
    if (c.intermediates.len != 0) return;

    const p0 = paramOr(c.params, 0, 1);
    switch (c.final) {
        'H', 'f' => { // CUP: row;col, 1-based
            const row = paramOr(c.params, 0, 1);
            const col = paramOr(c.params, 1, 1);
            self.moveTo(row -| 1, col -| 1);
        },
        'A' => self.moveTo(self.cursor.row -| p0, self.cursor.col), // CUU
        'B' => self.moveTo(self.cursor.row +| p0, self.cursor.col), // CUD
        'C' => self.moveTo(self.cursor.row, self.cursor.col +| p0), // CUF
        'D' => self.moveTo(self.cursor.row, self.cursor.col -| p0), // CUB
        'G' => self.moveTo(self.cursor.row, p0 -| 1), // CHA: column
        'd' => self.moveTo(p0 -| 1, self.cursor.col), // VPA: row
        'J' => self.eraseDisplay(paramOr(c.params, 0, 0)),
        'K' => self.eraseLine(paramOr(c.params, 0, 0)),
        'm' => self.sgr(c.params),
        else => {}, // unhandled CSI commands are ignored
    }
}

/// Clamp to the grid and clear pending wrap. All cursor motion goes through here.
fn moveTo(self: *Screen, row: u16, col: u16) void {
    self.cursor.row = @min(row, self.rows - 1);
    self.cursor.col = @min(col, self.cols - 1);
    self.pending_wrap = false;
}

fn eraseDisplay(self: *Screen, mode: u16) void {
    const cur = self.idx(self.cursor.row, self.cursor.col);
    switch (mode) {
        0 => @memset(self.cells[cur..], .{}), // cursor..end
        1 => @memset(self.cells[0 .. cur + 1], .{}), // start..cursor
        2, 3 => @memset(self.cells, .{}), // whole screen (3 also drops scrollback, which we lack)
        else => {},
    }
}

fn eraseLine(self: *Screen, mode: u16) void {
    const start = self.idx(self.cursor.row, 0);
    const end = start + self.cols;
    const cur = self.idx(self.cursor.row, self.cursor.col);
    switch (mode) {
        0 => @memset(self.cells[cur..end], .{}), // cursor..eol
        1 => @memset(self.cells[start .. cur + 1], .{}), // sol..cursor
        2 => @memset(self.cells[start..end], .{}), // whole line
        else => {},
    }
}

// --- SGR -------------------------------------------------------------------

fn sgr(self: *Screen, params: []const u16) void {
    if (params.len == 0) {
        self.pen = .{};
        return;
    }
    var i: usize = 0;
    while (i < params.len) : (i += 1) {
        switch (params[i]) {
            0 => self.pen = .{},
            1 => self.pen.attrs.bold = true,
            2 => self.pen.attrs.dim = true,
            3 => self.pen.attrs.italic = true,
            4 => self.pen.attrs.underline = true,
            5 => self.pen.attrs.blink = true,
            7 => self.pen.attrs.reverse = true,
            8 => self.pen.attrs.hidden = true,
            9 => self.pen.attrs.strike = true,
            22 => {
                self.pen.attrs.bold = false;
                self.pen.attrs.dim = false;
            },
            23 => self.pen.attrs.italic = false,
            24 => self.pen.attrs.underline = false,
            25 => self.pen.attrs.blink = false,
            27 => self.pen.attrs.reverse = false,
            28 => self.pen.attrs.hidden = false,
            29 => self.pen.attrs.strike = false,
            30...37 => self.pen.fg = .{ .palette = @truncate(params[i] - 30) },
            38 => i += self.extendedColor(params[i..], &self.pen.fg),
            39 => self.pen.fg = .default,
            40...47 => self.pen.bg = .{ .palette = @truncate(params[i] - 40) },
            48 => i += self.extendedColor(params[i..], &self.pen.bg),
            49 => self.pen.bg = .default,
            90...97 => self.pen.fg = .{ .palette = @truncate(params[i] - 90 + 8) },
            100...107 => self.pen.bg = .{ .palette = @truncate(params[i] - 100 + 8) },
            else => {}, // unknown SGR codes ignored
        }
    }
}

/// Parse a 38/48 extended color starting at `rest[0]` (the 38 or 48). Sets
/// `out` and returns how many EXTRA params were consumed (so the caller's index
/// advances past them). Handles `5;n` (palette) and `2;r;g;b` (RGB); colon and
/// semicolon separators look identical here because the parser flattens both.
fn extendedColor(self: *Screen, rest: []const u16, out: *Color) usize {
    _ = self;
    if (rest.len >= 3 and rest[1] == 5) {
        out.* = .{ .palette = @truncate(rest[2]) };
        return 2;
    }
    if (rest.len >= 5 and rest[1] == 2) {
        out.* = .{ .rgb = .{
            .r = @truncate(rest[2]),
            .g = @truncate(rest[3]),
            .b = @truncate(rest[4]),
        } };
        return 4;
    }
    return 0;
}

// --- OSC -------------------------------------------------------------------

fn osc(self: *Screen, cmd: @import("osc.zig").Command) void {
    const t = switch (cmd) {
        .change_window_title => |s| s,
        else => return,
    };
    const n = @min(t.len, self.title_buf.len);
    @memcpy(self.title_buf[0..n], t[0..n]);
    self.title_len = n;
}

/// The current window title (OSC 0/2), empty until one is set.
pub fn title(self: *const Screen) []const u8 {
    return self.title_buf[0..self.title_len];
}

/// Default per-param value when absent or zero (CSI params default to 1 for
/// motion, 0 for erase; the caller picks).
fn paramOr(params: []const u16, i: usize, default: u16) u16 {
    if (i >= params.len) return default;
    const v = params[i];
    return if (v == 0) default else v;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn expectRow(s: *const Screen, row: u16, want: []const u8) !void {
    var buf: [256]u8 = undefined;
    const got = std.mem.trimEnd(u8, s.rowText(row, &buf), " ");
    try testing.expectEqualStrings(want, got);
}

test "prints text on the first row" {
    var s = try Screen.init(testing.allocator, 4, 20);
    defer s.deinit();
    s.write("hello");
    try expectRow(&s, 0, "hello");
    try testing.expectEqual(@as(u16, 0), s.cursor.row);
    try testing.expectEqual(@as(u16, 5), s.cursor.col);
}

test "CR LF moves to next line column zero" {
    var s = try Screen.init(testing.allocator, 4, 20);
    defer s.deinit();
    s.write("ab\r\ncd");
    try expectRow(&s, 0, "ab");
    try expectRow(&s, 1, "cd");
}

test "deferred autowrap at end of line" {
    var s = try Screen.init(testing.allocator, 4, 4);
    defer s.deinit();
    s.write("abcde");
    try expectRow(&s, 0, "abcd");
    try expectRow(&s, 1, "e");
}

test "scrolls when output passes the last row" {
    var s = try Screen.init(testing.allocator, 3, 8);
    defer s.deinit();
    s.write("r0\r\nr1\r\nr2\r\nr3");
    try expectRow(&s, 0, "r1"); // r0 scrolled off
    try expectRow(&s, 1, "r2");
    try expectRow(&s, 2, "r3");
}

test "CSI cursor position then print" {
    var s = try Screen.init(testing.allocator, 5, 10);
    defer s.deinit();
    s.write("\x1b[2;3HX"); // row 2, col 3 (1-based)
    try testing.expectEqual(Cell{ .cp = 'X' }, s.cellAt(1, 2));
}

test "erase in line and display" {
    var s = try Screen.init(testing.allocator, 3, 8);
    defer s.deinit();
    s.write("abcdef\r\nghij");
    s.write("\x1b[1;1H"); // home
    s.write("\x1b[K"); // erase row 0 from cursor to EOL
    try expectRow(&s, 0, "");
    try expectRow(&s, 1, "ghij");
    s.write("\x1b[2J"); // erase whole display
    try expectRow(&s, 1, "");
}

test "SGR sets and resets the pen" {
    var s = try Screen.init(testing.allocator, 2, 10);
    defer s.deinit();
    s.write("\x1b[1;31mR\x1b[0mn");
    const r = s.cellAt(0, 0);
    try testing.expect(r.style.attrs.bold);
    try testing.expectEqual(Color{ .palette = 1 }, r.style.fg);
    const n = s.cellAt(0, 1);
    try testing.expect(!n.style.attrs.bold);
    try testing.expectEqual(Color.default, n.style.fg);
}

test "SGR 24-bit and 256 color" {
    var s = try Screen.init(testing.allocator, 2, 10);
    defer s.deinit();
    s.write("\x1b[38;2;10;20;30mA"); // RGB fg
    try testing.expectEqual(Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } }, s.cellAt(0, 0).style.fg);
    s.write("\x1b[48;5;200mB"); // 256-color bg
    try testing.expectEqual(Color{ .palette = 200 }, s.cellAt(0, 1).style.bg);
}

test "OSC sets the window title" {
    var s = try Screen.init(testing.allocator, 2, 10);
    defer s.deinit();
    s.write("\x1b]0;nether\x07rest");
    try testing.expectEqualStrings("nether", s.title());
    try expectRow(&s, 0, "rest"); // the text after the OSC still lands
}

test "ESC c resets the screen" {
    var s = try Screen.init(testing.allocator, 2, 10);
    defer s.deinit();
    s.write("\x1b[31mhi");
    s.write("\x1bc");
    try expectRow(&s, 0, "");
    try testing.expectEqual(Cursor{}, s.cursor);
    try testing.expectEqual(Color.default, s.pen.fg);
}

test "a realistic colored prompt renders" {
    var s = try Screen.init(testing.allocator, 4, 40);
    defer s.deinit();
    // bold-green "user@host" reset ":" then "~ $ "
    s.write("\x1b[1;32muser@host\x1b[0m:\x1b[1;34m~\x1b[0m$ ");
    try expectRow(&s, 0, "user@host:~$");
    try testing.expect(s.cellAt(0, 0).style.attrs.bold);
    try testing.expectEqual(Color{ .palette = 2 }, s.cellAt(0, 0).style.fg); // green
    try testing.expectEqual(Color.default, s.cellAt(0, 9).style.fg); // the ':' reset
}
