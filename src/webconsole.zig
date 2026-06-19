//! Read-only web console: serve the guest's terminal grid as HTML.
//!
//! The grid (src/vt/Screen.zig) already emulates the terminal server-side, so
//! the browser does not need a terminal emulator: we render the live screen to
//! styled HTML and the page just displays it, polling for updates. Two parts:
//!
//!   - renderGrid: pure, fully tested, turns a Screen into an HTML fragment.
//!   - Server: a minimal HTTP/1.1 server over raw linux syscalls (matching the
//!     rest of Nether, which avoids std.Io), Linux-only. Cross-compiles on any
//!     host; runs on the KVM box.
//!
//! Concurrency (D3): the server thread reads the Screen while the serial tee
//! writes it on the vCPU thread, so the integration owns a Lock shared by both.
//! The Screen itself stays pure. Input (browser -> guest) is a later addition;
//! this is read-only.

const std = @import("std");
const linux = std.os.linux;
const Screen = @import("vt/Screen.zig");
const Color = Screen.Color;
const Style = Screen.Style;
const Lock = @import("lock.zig").Lock;

// --- HTML rendering (pure) -------------------------------------------------

/// A bounded byte appender. Overflows truncate rather than crash, so a
/// pathological grid degrades to a clipped render, never a panic.
const Buf = struct {
    data: []u8,
    len: usize = 0,

    fn add(self: *Buf, s: []const u8) void {
        const n = @min(s.len, self.data.len - self.len);
        @memcpy(self.data[self.len..][0..n], s[0..n]);
        self.len += n;
    }
    fn print(self: *Buf, comptime fmt: []const u8, args: anytype) void {
        const w = std.fmt.bufPrint(self.data[self.len..], fmt, args) catch return;
        self.len += w.len;
    }
    fn slice(self: *const Buf) []const u8 {
        return self.data[0..self.len];
    }
};

/// Render the live screen to an HTML fragment: a `<pre class="t">` whose rows
/// are runs of `<span>`s coalesced by identical style. `out` should be sized for
/// the worst case (~ rows*cols*64 bytes); overflow clips.
pub fn renderGrid(screen: *const Screen, out: *Buf) void {
    // Keep id="s" so the page's poller (which swaps via outerHTML) can find the
    // element again on the next tick.
    out.add("<pre id=\"s\" class=\"t\">");
    var row: u16 = 0;
    while (row < screen.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < screen.cols) {
            const style = screen.cellAt(row, col).style;
            var end = col;
            while (end < screen.cols and std.meta.eql(screen.cellAt(row, end).style, style)) : (end += 1) {}
            openSpan(out, style);
            var c = col;
            while (c < end) : (c += 1) appendCp(out, screen.cellAt(row, c).cp);
            out.add("</span>");
            col = end;
        }
        out.add("\n");
    }
    out.add("</pre>");
}

fn appendCp(out: *Buf, cp: u21) void {
    switch (cp) {
        '<' => out.add("&lt;"),
        '>' => out.add("&gt;"),
        '&' => out.add("&amp;"),
        else => {
            var b: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &b) catch {
                out.add("\u{fffd}");
                return;
            };
            out.add(b[0..n]);
        },
    }
}

fn isDefault(style: Style) bool {
    return std.meta.eql(style, Style{});
}

fn openSpan(out: *Buf, style: Style) void {
    if (isDefault(style)) {
        out.add("<span>");
        return;
    }
    out.add("<span style=\"");

    // Reverse video swaps fg/bg, resolving defaults to concrete values so the
    // swap is visible.
    if (style.attrs.reverse) {
        out.add("color:");
        writeColor(out, style.bg, default_bg);
        out.add(";background:");
        writeColor(out, style.fg, default_fg);
        out.add(";");
    } else {
        if (style.fg != .default) {
            out.add("color:");
            writeColor(out, style.fg, default_fg);
            out.add(";");
        }
        if (style.bg != .default) {
            out.add("background:");
            writeColor(out, style.bg, default_bg);
            out.add(";");
        }
    }

    if (style.attrs.bold) out.add("font-weight:bold;");
    if (style.attrs.italic) out.add("font-style:italic;");
    if (style.attrs.dim) out.add("opacity:0.6;");
    if (style.attrs.hidden) out.add("visibility:hidden;");
    if (style.attrs.underline and style.attrs.strike)
        out.add("text-decoration:underline line-through;")
    else if (style.attrs.underline)
        out.add("text-decoration:underline;")
    else if (style.attrs.strike)
        out.add("text-decoration:line-through;");

    out.add("\">");
}

const default_fg = [3]u8{ 0xdd, 0xdd, 0xdd };
const default_bg = [3]u8{ 0x00, 0x00, 0x00 };

fn writeColor(out: *Buf, color: Color, dflt: [3]u8) void {
    const rgb = switch (color) {
        .default => dflt,
        .palette => |p| paletteRgb(p),
        .rgb => |c| [3]u8{ c.r, c.g, c.b },
    };
    out.print("#{x:0>2}{x:0>2}{x:0>2}", .{ rgb[0], rgb[1], rgb[2] });
}

/// xterm 256-color palette: 16 base colors, a 6x6x6 cube, then a grayscale ramp.
fn paletteRgb(n: u8) [3]u8 {
    if (n < 16) return base16[n];
    if (n < 232) {
        const i = n - 16;
        return .{ cube(i / 36), cube((i / 6) % 6), cube(i % 6) };
    }
    const g: u8 = 8 + (n - 232) * 10;
    return .{ g, g, g };
}

fn cube(c: u8) u8 {
    return if (c == 0) 0 else 55 + c * 40;
}

const base16 = [16][3]u8{
    .{ 0x00, 0x00, 0x00 }, .{ 0xcd, 0x00, 0x00 }, .{ 0x00, 0xcd, 0x00 }, .{ 0xcd, 0xcd, 0x00 },
    .{ 0x00, 0x00, 0xee }, .{ 0xcd, 0x00, 0xcd }, .{ 0x00, 0xcd, 0xcd }, .{ 0xe5, 0xe5, 0xe5 },
    .{ 0x7f, 0x7f, 0x7f }, .{ 0xff, 0x00, 0x00 }, .{ 0x00, 0xff, 0x00 }, .{ 0xff, 0xff, 0x00 },
    .{ 0x5c, 0x5c, 0xff }, .{ 0xff, 0x00, 0xff }, .{ 0x00, 0xff, 0xff }, .{ 0xff, 0xff, 0xff },
};

/// The page shell: polls /grid and swaps in the fragment. Self-contained.
const page =
    \\<!doctype html><html><head><meta charset="utf-8"><title>nether console</title>
    \\<style>html,body{margin:0;background:#000}.t{font:14px/1.2 ui-monospace,monospace;
    \\color:#ddd;background:#000;padding:8px;white-space:pre;tab-size:8}</style></head>
    \\<body><pre id="s" class="t">connecting...</pre><script>
    \\async function tick(){try{const r=await fetch("/grid");
    \\document.getElementById("s").outerHTML=await r.text();}catch(e){}setTimeout(tick,250)}
    \\tick();</script></body></html>
;

// --- HTTP server (raw syscalls, Linux only) --------------------------------

pub const Server = struct {
    screen: *Screen,
    lock: *Lock,
    port: u16,
    /// Scratch buffer for rendering one response. Caller-owned; size it for the
    /// worst-case grid (~256 KiB is ample for 80x24).
    buf: []u8,

    /// Bind, listen, and serve forever. Returns on a fatal setup error (e.g.
    /// the port is taken), so the caller can run it on a detached thread.
    pub fn run(self: *Server) void {
        const fd_u = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
        if (linux.errno(fd_u) != .SUCCESS) return;
        const fd: i32 = @intCast(fd_u);
        defer _ = linux.close(fd);

        const one: u32 = 1;
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), 4);

        const addr = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, self.port), .addr = 0 };
        if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return;
        if (linux.errno(linux.listen(fd, 16)) != .SUCCESS) return;

        while (true) {
            const conn_u = linux.accept(fd, null, null);
            if (linux.errno(conn_u) != .SUCCESS) continue;
            const conn: i32 = @intCast(conn_u);
            self.handle(conn);
            _ = linux.close(conn);
        }
    }

    fn handle(self: *Server, conn: i32) void {
        var req: [2048]u8 = undefined;
        const n = linux.read(conn, &req, req.len);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        const path = parsePath(req[0..n]);

        if (std.mem.eql(u8, path, "/grid")) {
            var b = Buf{ .data = self.buf };
            self.lock.lock();
            renderGrid(self.screen, &b);
            self.lock.unlock();
            respond(conn, b.slice());
        } else {
            respond(conn, page);
        }
    }
};

fn parsePath(req: []const u8) []const u8 {
    const s = std.mem.indexOfScalar(u8, req, ' ') orelse return "/";
    const rest = req[s + 1 ..];
    const e = std.mem.indexOfScalar(u8, rest, ' ') orelse return "/";
    return rest[0..e];
}

fn respond(conn: i32, body: []const u8) void {
    var hdr: [160]u8 = undefined;
    const h = std.fmt.bufPrint(
        &hdr,
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{body.len},
    ) catch return;
    writeAll(conn, h);
    writeAll(conn, body);
}

fn writeAll(conn: i32, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = linux.write(conn, data.ptr + off, data.len - off);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        off += n;
    }
}

// --- tests (renderer only; the server is Linux-only) -----------------------

const testing = std.testing;

fn render(screen: *const Screen, buf: []u8) []const u8 {
    var b = Buf{ .data = buf };
    renderGrid(screen, &b);
    return b.slice();
}

test "renders plain text rows as default spans" {
    var s = try Screen.init(testing.allocator, 1, 8);
    defer s.deinit();
    s.write("hi");
    var buf: [4096]u8 = undefined;
    const html = render(&s, &buf);
    try testing.expect(std.mem.indexOf(u8, html, "<pre id=\"s\" class=\"t\">") != null);
    try testing.expect(std.mem.indexOf(u8, html, "hi") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<span>") != null); // default style
}

test "escapes HTML metacharacters" {
    var s = try Screen.init(testing.allocator, 1, 8);
    defer s.deinit();
    s.write("a<b>&c");
    var buf: [4096]u8 = undefined;
    const html = render(&s, &buf);
    try testing.expect(std.mem.indexOf(u8, html, "&lt;b&gt;&amp;c") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<b>") == null); // not raw
}

test "emits color for SGR styled cells" {
    var s = try Screen.init(testing.allocator, 1, 8);
    defer s.deinit();
    s.write("\x1b[31mR"); // red fg (palette 1 -> #cd0000)
    var buf: [4096]u8 = undefined;
    const html = render(&s, &buf);
    try testing.expect(std.mem.indexOf(u8, html, "color:#cd0000") != null);
}

test "24-bit color renders exact rgb" {
    var s = try Screen.init(testing.allocator, 1, 8);
    defer s.deinit();
    s.write("\x1b[38;2;1;2;3mX");
    var buf: [4096]u8 = undefined;
    const html = render(&s, &buf);
    try testing.expect(std.mem.indexOf(u8, html, "color:#010203") != null);
}

test "reverse video swaps to concrete colors" {
    var s = try Screen.init(testing.allocator, 1, 8);
    defer s.deinit();
    s.write("\x1b[7mX"); // reverse with default fg/bg
    var buf: [4096]u8 = undefined;
    const html = render(&s, &buf);
    try testing.expect(std.mem.indexOf(u8, html, "color:#000000") != null); // was bg
    try testing.expect(std.mem.indexOf(u8, html, "background:#dddddd") != null); // was fg
}

test "bold and underline become CSS" {
    var s = try Screen.init(testing.allocator, 1, 8);
    defer s.deinit();
    s.write("\x1b[1;4mX");
    var buf: [4096]u8 = undefined;
    const html = render(&s, &buf);
    try testing.expect(std.mem.indexOf(u8, html, "font-weight:bold") != null);
    try testing.expect(std.mem.indexOf(u8, html, "text-decoration:underline") != null);
}

test "coalesces a run of same-style cells into one span" {
    var s = try Screen.init(testing.allocator, 1, 8);
    defer s.deinit();
    s.write("\x1b[31mabc");
    var buf: [4096]u8 = undefined;
    const html = render(&s, &buf);
    // One opening span carries the whole "abc" run, not three.
    try testing.expect(std.mem.indexOf(u8, html, "color:#cd0000;\">abc") != null);
}

test "parsePath extracts the request target" {
    try testing.expectEqualStrings("/grid", parsePath("GET /grid HTTP/1.1\r\n"));
    try testing.expectEqualStrings("/", parsePath("GET / HTTP/1.1\r\n"));
    try testing.expectEqualStrings("/", parsePath("garbage-no-spaces"));
}

test "render truncates instead of overflowing a small buffer" {
    var s = try Screen.init(testing.allocator, 4, 80);
    defer s.deinit();
    s.write("lots of text here");
    var small: [16]u8 = undefined;
    const html = render(&s, &small);
    try testing.expect(html.len <= small.len); // clipped, no panic
}
