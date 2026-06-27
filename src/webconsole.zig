//! Read-only web console: serve the guest's terminal grid as HTML.
//!
//! The grid (src/vt/Screen.zig) already emulates the terminal server-side, so
//! the browser does not need a terminal emulator: we render the live screen to
//! styled HTML and the page just displays it, polling for updates. Parts:
//!
//!   - renderGrid: pure, fully tested, turns a Screen into an HTML fragment.
//!   - Server: a minimal HTTP/1.1 server over raw linux syscalls (matching the
//!     rest of Nether, which avoids std.Io), Linux-only. Cross-compiles on any
//!     host; runs on the KVM box. GET / serves the page, GET /grid the fragment,
//!     POST /input forwards keystrokes.
//!   - Input: the page maps key presses to terminal byte sequences and POSTs
//!     them; the server hands them to an `on_input` sink (wired to the serial RX).
//!
//! Concurrency (D3): the server thread reads the Screen while the serial tee
//! writes it on the vCPU thread, so the integration owns a Lock shared by both.
//! The Screen itself stays pure. Input goes to the serial RX, whose pushRx is
//! already internally locked, so it is safe to call from the web thread.

const std = @import("std");
const linux = std.os.linux;
const Screen = @import("vt/Screen.zig");
const Color = Screen.Color;
const Style = Screen.Style;
const Lock = @import("common/lock.zig").Lock;

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

/// The page shell: polls /grid and swaps in the fragment, and forwards key
/// presses (mapped to terminal byte sequences) to /input. Self-contained.
const page =
    \\<!doctype html><html><head><meta charset="utf-8"><title>nether console</title>
    \\<style>html,body{margin:0;background:#000}.t{font:14px/1.2 ui-monospace,monospace;
    \\color:#ddd;background:#000;padding:8px;white-space:pre;tab-size:8}</style></head>
    \\<body><pre id="s" class="t">connecting...</pre><script>
    \\const Q=location.search;
    \\async function tick(){try{const r=await fetch("/grid"+Q);
    \\document.getElementById("s").outerHTML=await r.text();}catch(e){}setTimeout(tick,250)}
    \\function key(e){
    \\if(e.ctrlKey&&e.key.length===1){const c=e.key.toUpperCase().charCodeAt(0);
    \\if(c>=64&&c<=95)return String.fromCharCode(c-64);}
    \\switch(e.key){case"Enter":return"\r";case"Backspace":return"\x7f";case"Tab":return"\t";
    \\case"Escape":return"\x1b";case"ArrowUp":return"\x1b[A";case"ArrowDown":return"\x1b[B";
    \\case"ArrowRight":return"\x1b[C";case"ArrowLeft":return"\x1b[D";case"Home":return"\x1b[H";
    \\case"End":return"\x1b[F";case"Delete":return"\x1b[3~";}
    \\if(e.key.length===1&&!e.ctrlKey&&!e.metaKey)return e.key;return null}
    \\addEventListener("keydown",e=>{const s=key(e);
    \\if(s!==null){e.preventDefault();fetch("/input"+Q,{method:"POST",body:s});}});
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
    /// Optional sink for browser keystrokes (POST /input), wired to the serial
    /// RX. Decoupled via a callback so this module needn't depend on Serial. The
    /// callback may be invoked from this (the web) thread; the serial RX is
    /// already safe to push from another thread.
    on_input: ?*const fn (*anyopaque, []const u8) void = null,
    on_input_ctx: ?*anyopaque = null,
    /// Per-process access token (hex of 16 random bytes), generated in `run`. Every
    /// request must carry `?t=<token>`; without it the console (and its keystroke
    /// injection) is refused, so other local processes that did not see the
    /// operator's URL cannot drive it even though the port is loopback.
    token: [32]u8 = undefined,

    /// Bind, listen, and serve forever. Returns on a fatal setup error (e.g.
    /// the port is taken), so the caller can run it on a detached thread.
    pub fn run(self: *Server) void {
        // Mint a fresh access token for this process before listening. Without OS
        // randomness we refuse to serve rather than fall back to a guessable token.
        var raw: [16]u8 = undefined;
        if (linux.getrandom(&raw, raw.len, 0) != raw.len) return;
        self.token = std.fmt.bytesToHex(raw, .lower);

        const fd_u = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
        if (linux.errno(fd_u) != .SUCCESS) return;
        const fd: i32 = @intCast(fd_u);
        defer _ = linux.close(fd);

        const one: u32 = 1;
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), 4);

        // Bind loopback only: POST /input injects keystrokes into the guest serial
        // console, so the console must never be reachable off-host. 127.0.0.1 in
        // network byte order (0 would be INADDR_ANY = every interface).
        const addr = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, self.port), .addr = std.mem.nativeToBig(u32, 0x7f00_0001) };
        if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return;
        if (linux.errno(linux.listen(fd, 16)) != .SUCCESS) return;
        std.debug.print("[web] console: http://127.0.0.1:{d}/?t={s}\n", .{ self.port, self.token });

        while (true) {
            const conn_u = linux.accept(fd, null, null);
            if (linux.errno(conn_u) != .SUCCESS) continue;
            const conn: i32 = @intCast(conn_u);
            self.handle(conn);
            _ = linux.close(conn);
        }
    }

    fn handle(self: *Server, conn: i32) void {
        var req: [4096]u8 = undefined;
        const n = linux.read(conn, &req, req.len);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        const target = parsePath(req[0..n]);
        const qpos = std.mem.indexOfScalar(u8, target, '?');
        const path = if (qpos) |q| target[0..q] else target;
        const query = if (qpos) |q| target[q + 1 ..] else "";

        // Token gate: every route (page, /grid, /input) requires ?t=<token>. The
        // page's JS carries it forward via location.search, so a client that never
        // saw the operator's URL cannot reach keystroke injection or the screen.
        if (!self.authed(query)) {
            writeAll(conn, "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            return;
        }

        if (std.mem.eql(u8, path, "/input")) {
            self.deliverInput(conn, &req, n);
            respondEmpty(conn);
        } else if (std.mem.eql(u8, path, "/grid")) {
            var b = Buf{ .data = self.buf };
            self.lock.lock();
            renderGrid(self.screen, &b);
            self.lock.unlock();
            respond(conn, b.slice());
        } else {
            respond(conn, page);
        }
    }

    /// Forward a POST /input body to the input sink. `req[0..n]` is what we have
    /// read so far; we read the rest of the body if it has not all arrived.
    fn deliverInput(self: *Server, conn: i32, req: []u8, n_read: usize) void {
        const cb = self.on_input orelse return;
        const ctx = self.on_input_ctx orelse return;
        const sep = std.mem.indexOf(u8, req[0..n_read], "\r\n\r\n") orelse return;
        const body_start = sep + 4;
        const want = contentLength(req[0..body_start]);
        var have = n_read - body_start;
        while (have < want and body_start + have < req.len) {
            const m = linux.read(conn, req.ptr + body_start + have, req.len - (body_start + have));
            if (linux.errno(m) != .SUCCESS or m == 0) break;
            have += m;
        }
        const body_len = @min(have, want);
        if (body_len > 0) cb(ctx, req[body_start .. body_start + body_len]);
    }

    /// True if the request query carries the matching `t=<token>`.
    fn authed(self: *const Server, query: []const u8) bool {
        const tok = tokenParam(query);
        return tok.len == self.token.len and std.mem.eql(u8, &self.token, tok);
    }
};

/// Extract the `t` query parameter value (empty if absent). `query` is the part
/// after '?', e.g. "t=abc123" or "x=1&t=abc123".
fn tokenParam(query: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv, "t=")) return kv[2..];
    }
    return "";
}

/// Parse the Content-Length header value (0 if absent/unparseable).
fn contentLength(req: []const u8) usize {
    var it = std.mem.splitScalar(u8, req, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const v = std.mem.trim(u8, line["content-length:".len..], " ");
            return std.fmt.parseInt(usize, v, 10) catch 0;
        }
    }
    return 0;
}

fn respondEmpty(conn: i32) void {
    writeAll(conn, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
}

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

test "tokenParam and the auth gate accept only the exact token" {
    try testing.expectEqualStrings("abc", tokenParam("t=abc"));
    try testing.expectEqualStrings("abc", tokenParam("x=1&t=abc"));
    try testing.expectEqualStrings("", tokenParam("x=1")); // absent
    try testing.expectEqualStrings("", tokenParam("")); // empty query

    const tok = "0123456789abcdef0123456789abcdef"; // 32 hex chars
    var s: Server = undefined;
    @memcpy(&s.token, tok);
    try testing.expect(s.authed("t=" ++ tok));
    try testing.expect(!s.authed("t=wrong"));
    try testing.expect(!s.authed("")); // no token => refused
    try testing.expect(!s.authed("t=" ++ tok ++ "x")); // longer
}

test "contentLength parses the header case-insensitively" {
    try testing.expectEqual(@as(usize, 5), contentLength("POST /input HTTP/1.1\r\nContent-Length: 5\r\n\r\n"));
    try testing.expectEqual(@as(usize, 12), contentLength("POST / HTTP/1.1\r\ncontent-length:12\r\n\r\n"));
    try testing.expectEqual(@as(usize, 0), contentLength("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
}

test "page carries the keydown forwarder" {
    try testing.expect(std.mem.indexOf(u8, page, "keydown") != null);
    try testing.expect(std.mem.indexOf(u8, page, "/input") != null);
}

test "render truncates instead of overflowing a small buffer" {
    var s = try Screen.init(testing.allocator, 4, 80);
    defer s.deinit();
    s.write("lots of text here");
    var small: [16]u8 = undefined;
    const html = render(&s, &small);
    try testing.expect(html.len <= small.len); // clipped, no panic
}
