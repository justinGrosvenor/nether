//! Control plane: the Unix-domain control socket and the in-guest agent plumbing
//! the platform drives a sandbox through. Command relay, host-mediated file
//! push/pull (__put__/__get__), the __stats__ metering report, and the
//! __shutdown__ lifecycle command all live here, off the boot orchestration in
//! main.zig.

const std = @import("std");
const nether = @import("root.zig");
const hostutil = @import("hostutil.zig");

const libc = hostutil.libc;
const usleep = hostutil.usleep;
const nowMs = hostutil.nowMs;
const readFileMac = hostutil.readFileMac;
const writeAll = hostutil.writeAll;
const cpath = hostutil.cpath;
const SockaddrUn = hostutil.SockaddrUn;
const AF_UNIX = hostutil.AF_UNIX;
const SOCK_STREAM = hostutil.SOCK_STREAM;

/// Per-sandbox resource usage, exposed to the platform (which settles per use)
/// via the `__stats__` control command. Counters are shared across the control
/// threads; the platform reads them to meter compute, RAM, and I/O.
pub const Metering = struct {
    start_ms: i64 = 0,
    ram_mb: u64 = 0,
    cpus: u32 = 0,
    commands: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    bytes_in: std.atomic.Value(u64) = std.atomic.Value(u64).init(0), // client -> sandbox
    bytes_out: std.atomic.Value(u64) = std.atomic.Value(u64).init(0), // sandbox -> client
    net: ?*nether.Slirp = null, // network NAT, for egress/ingress byte counts

    /// Render a stats report (text + the agent's 0x1e<exit>\n framing) into `buf`.
    fn report(self: *Metering, buf: []u8) usize {
        const net_tx = if (self.net) |s| s.tx_bytes.load(.monotonic) else 0;
        const net_rx = if (self.net) |s| s.rx_bytes.load(.monotonic) else 0;
        const net_blocked = if (self.net) |s| s.blocked_count.load(.monotonic) else 0;
        return (std.fmt.bufPrint(buf,
            \\nether sandbox stats
            \\uptime_ms={d}
            \\ram_mb={d}
            \\cpus={d}
            \\commands={d}
            \\bytes_in={d}
            \\bytes_out={d}
            \\net_tx_bytes={d}
            \\net_rx_bytes={d}
            \\net_blocked={d}
            \\{c}0
            \\
        , .{
            nowMs() - self.start_ms,
            self.ram_mb,
            self.cpus,
            self.commands.load(.acquire),
            self.bytes_in.load(.acquire),
            self.bytes_out.load(.acquire),
            net_tx,
            net_rx,
            net_blocked,
            @as(u8, 0x1e),
        }) catch return 0).len;
    }
};

/// Clean sandbox stop: request a PSCI-style poweroff, then force the vCPUs out of
/// `hv_vcpu_run` (re-fired for any between runs or parked in WFI) so the run loop
/// observes the action and returns `.shutdown` - cpu0's return unwinds macBootLinux
/// and the process exits. Shared by the runtime watchdog and __shutdown__.
pub fn stopSandbox(power: *nether.Power, handles: []const u64, num_cpus: u32) void {
    const hvf = @import("hvf.zig");
    power.request(.shutdown);
    var tries: u32 = 0;
    while (tries < 50) : (tries += 1) {
        _ = hvf.hv_vcpus_exit(handles.ptr, num_cpus);
        _ = usleep(20_000);
    }
}

/// A diverted capture of the agent's reply, used by the host-mediated file
/// transfer (`__put__`/`__get__`). While `AgentCtx.capture` points at one of these,
/// agent reply bytes accumulate here instead of being relayed; the control thread
/// waits on `done`, then reads the result. Single op at a time (the control
/// protocol is serial), so no queue is needed.
const Capture = struct {
    is_get: bool, // GET parses "OK <len>\n" + body; PUT parses one "OK\n"/"ERR\n" line
    buf: []u8, // accumulation (header+body for GET; tiny for PUT)
    len: usize = 0,
    body_off: usize = 0, // GET: where the file body starts (after the "OK <len>\n" header)
    expect: usize = 0, // GET: total bytes expected (body_off + file len); 0 until parsed
    err: bool = false,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn feed(self: *Capture, bytes: []const u8) void {
        const n = @min(bytes.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], bytes[0..n]);
        self.len += n;
        if (!self.is_get) { // PUT: a single status line
            if (std.mem.indexOfScalar(u8, self.buf[0..self.len], '\n') != null) {
                self.err = !std.mem.startsWith(u8, self.buf[0..self.len], "OK");
                self.done.store(true, .release);
            }
            return;
        }
        if (self.expect == 0) { // GET: still parsing the "OK <len>\n" / "ERR\n" header
            const nl = std.mem.indexOfScalar(u8, self.buf[0..self.len], '\n') orelse return;
            const hdr = self.buf[0..nl];
            if (!std.mem.startsWith(u8, hdr, "OK ")) {
                self.err = true;
                self.done.store(true, .release);
                return;
            }
            const flen = std.fmt.parseInt(usize, hdr[3..], 10) catch {
                self.err = true;
                self.done.store(true, .release);
                return;
            };
            self.body_off = nl + 1;
            if (flen > self.buf.len - self.body_off) { // larger than our cap
                self.err = true;
                self.done.store(true, .release);
                return;
            }
            self.expect = self.body_off + flen;
        }
        if (self.expect != 0 and self.len >= self.expect) self.done.store(true, .release);
    }
};

pub const AgentCtx = struct {
    conn_id: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),
    /// Control-socket mode: agent replies are written raw to this pipe for the
    /// relay thread to forward to the connected control client. -1 = REPL mode
    /// (parse and print to stdout instead).
    pipe_w: i32 = -1,
    /// When set, agent reply bytes are diverted into this capture (file transfer)
    /// instead of relayed/printed. Set/cleared by the control thread.
    capture: std.atomic.Value(?*Capture) = std.atomic.Value(?*Capture).init(null),
    /// The render pillar: when set, command output is teed into a VT screen so the
    /// platform can fetch a rendered snapshot via `__screen__`.
    render: ?*nether.Render = null,
    parsing_exit: bool = false, // mid-parse of the 0x1e<code>\n trailer
    exit_buf: [16]u8 = undefined,
    exit_len: usize = 0,

    /// Parse the agent's framed reply stream: raw output up to 0x1e, then the
    /// command's exit code, printed as a `[exit N]` line.
    fn onRecv(a: *AgentCtx, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            if (a.parsing_exit) {
                if (bytes[i] == '\n') {
                    std.debug.print("[exit {s}]\n", .{a.exit_buf[0..a.exit_len]});
                    a.parsing_exit = false;
                    a.exit_len = 0;
                } else if (a.exit_len < a.exit_buf.len) {
                    a.exit_buf[a.exit_len] = bytes[i];
                    a.exit_len += 1;
                }
                i += 1;
            } else {
                const start = i;
                while (i < bytes.len and bytes[i] != 0x1e) i += 1;
                if (i > start) _ = std.c.write(1, bytes[start..].ptr, i - start);
                if (i < bytes.len) { // hit the 0x1e separator
                    a.parsing_exit = true;
                    i += 1;
                }
            }
        }
    }
};

pub fn agentEvent(ctx: *anyopaque, ev: nether.vsock.Event) void {
    const a: *AgentCtx = @ptrCast(@alignCast(ctx));
    switch (ev) {
        .accept => |id| {
            a.conn_id.store(@intCast(id), .release);
            std.debug.print("[agent] guest agent connected; type commands (they run in the sandbox)\n", .{});
        },
        .recv => |r| if (a.capture.load(.acquire)) |cap| {
            cap.feed(r.bytes); // file transfer in progress: divert the reply
        } else {
            if (a.render) |rd| rd.feed(r.bytes); // tee command output into the render screen
            if (a.pipe_w >= 0) {
                _ = libc.write(a.pipe_w, r.bytes.ptr, r.bytes.len); // -> relay -> control client
            } else a.onRecv(r.bytes);
        },
        .shutdown, .reset => a.conn_id.store(-1, .release),
        else => {},
    }
}

/// Control plane: a Unix-domain socket the platform connects to in order to drive
/// the in-guest agent without owning this process's stdio. One control client at
/// a time: its command lines are forwarded to the agent over vsock, and the
/// agent's framed replies are relayed back. The framing (output + 0x1e<exit>\n) is
/// the agent's, so the client parses results just as a stdio driver would.
pub const ControlCtx = struct {
    vsdev: *nether.VsockDev,
    agent: *AgentCtx,
    meter: *Metering,
    path: [*:0]const u8,
    pipe_r: i32,
    allocator: std.mem.Allocator,
    power: *nether.Power, // for the __shutdown__ lifecycle command
    handles: []const u64, // vCPU handles to force out on shutdown
    num_cpus: u32,
    gpu: ?*nether.VirtioGpu = null, // for the __frame__ render command
    client: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),
};

/// Max bytes a single `__put__`/`__get__` moves. Bounds host memory and frames the
/// guest-side payload; large enough for typical task payloads/artifacts.
const MAX_XFER: usize = 16 * 1024 * 1024;

/// Send `data` to the guest agent, retrying as its staging ring drains (hostSend
/// accepts only what fits). Returns false if the connection dies mid-send.
fn hostSendAll(vsdev: *nether.VsockDev, id: u16, data: []const u8) bool {
    var off: usize = 0;
    var stalls: u32 = 0;
    while (off < data.len) {
        const sent = vsdev.hostSend(id, data[off..]);
        if (sent == 0) {
            stalls += 1;
            if (stalls > 100_000) return false; // ~ guest not draining
            _ = usleep(100);
        } else {
            off += sent;
            stalls = 0;
        }
    }
    return true;
}

/// Wait (bounded) for a diverted capture to complete.
fn waitCapture(cap: *Capture) bool {
    var spins: u32 = 0;
    while (!cap.done.load(.acquire)) {
        spins += 1;
        if (spins > 600_000) return false; // ~60s ceiling
        _ = usleep(100);
    }
    return true;
}

/// Host-mediated file push: read the host file and stream it to the guest agent as
/// a __PUT__ request. `args` = "<hostpath> <guestpath>".
fn controlPut(ctx: *ControlCtx, c: c_int, id: u16, args: []const u8) void {
    const sp = std.mem.indexOfScalar(u8, args, ' ') orelse return reply(c, "ERR bad __put__ (need <hostpath> <guestpath>)\n");
    const hostpath = std.mem.trim(u8, args[0..sp], " \t\r\n");
    const guestpath = std.mem.trim(u8, args[sp + 1 ..], " \t\r\n");
    var pb: [1024]u8 = undefined;
    const hp = cpath(&pb, hostpath) orelse return reply(c, "ERR host path too long\n");
    const data = readFileMac(ctx.allocator, hp) catch return reply(c, "ERR cannot read host file\n");
    defer ctx.allocator.free(data);
    if (data.len > MAX_XFER) return reply(c, "ERR file too large\n");

    var rbuf: [8]u8 = undefined;
    var cap = Capture{ .is_get = false, .buf = &rbuf };
    ctx.agent.capture.store(&cap, .release);
    defer ctx.agent.capture.store(null, .release);

    var hdr: [4096]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "__PUT__ {s} {d}\n", .{ guestpath, data.len }) catch return reply(c, "ERR guest path too long\n");
    if (!hostSendAll(ctx.vsdev, id, h) or !hostSendAll(ctx.vsdev, id, data)) return reply(c, "ERR send failed\n");
    if (!waitCapture(&cap) or cap.err) return reply(c, "ERR guest write failed\n");
    var ok: [128]u8 = undefined;
    reply(c, std.fmt.bufPrint(&ok, "OK put {d} bytes -> {s}\n", .{ data.len, guestpath }) catch "OK\n");
}

/// Host-mediated file pull: request a file from the guest agent and write it to the
/// host. `args` = "<guestpath> <hostpath>".
fn controlGet(ctx: *ControlCtx, c: c_int, id: u16, args: []const u8) void {
    const sp = std.mem.indexOfScalar(u8, args, ' ') orelse return reply(c, "ERR bad __get__ (need <guestpath> <hostpath>)\n");
    const guestpath = std.mem.trim(u8, args[0..sp], " \t\r\n");
    const hostpath = std.mem.trim(u8, args[sp + 1 ..], " \t\r\n");

    const cbuf = ctx.allocator.alloc(u8, MAX_XFER + 64) catch return reply(c, "ERR out of memory\n");
    defer ctx.allocator.free(cbuf);
    var cap = Capture{ .is_get = true, .buf = cbuf };
    ctx.agent.capture.store(&cap, .release);
    defer ctx.agent.capture.store(null, .release);

    var hdr: [4096]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "__GET__ {s}\n", .{guestpath}) catch return reply(c, "ERR guest path too long\n");
    if (!hostSendAll(ctx.vsdev, id, h)) return reply(c, "ERR send failed\n");
    if (!waitCapture(&cap) or cap.err) return reply(c, "ERR guest read failed (missing?)\n");
    const body = cap.buf[cap.body_off..cap.expect];

    var pb: [1024]u8 = undefined;
    const hp = cpath(&pb, hostpath) orelse return reply(c, "ERR host path too long\n");
    const O_WRONLY = 0x0001;
    const O_CREAT = 0x0200;
    const O_TRUNC = 0x0400;
    const fd = libc.open(hp, O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
    if (fd < 0) return reply(c, "ERR cannot write host file\n");
    defer _ = libc.close(fd);
    if (!writeAll(fd, body)) return reply(c, "ERR write failed\n");
    var ok: [128]u8 = undefined;
    reply(c, std.fmt.bufPrint(&ok, "OK got {d} bytes -> {s}\n", .{ body.len, hostpath }) catch "OK\n");
}

fn reply(c: c_int, msg: []const u8) void {
    _ = libc.write(c, msg.ptr, msg.len);
}

/// Send one command line to the guest agent (waiting for it to connect), counting
/// it for metering. `__stats__` and `__shutdown__` are intercepted here and
/// answered by the host without touching the guest.
fn controlCommand(ctx: *ControlCtx, c: c_int, line: []const u8) void {
    if (std.mem.eql(u8, line, "__stats__\n") or std.mem.eql(u8, line, "__stats__")) {
        var rep: [512]u8 = undefined;
        const n = ctx.meter.report(&rep);
        _ = libc.write(c, rep[0..n].ptr, n);
        _ = ctx.meter.bytes_out.fetchAdd(n, .release);
        return;
    }
    // Render: full snapshot of the sandbox terminal (scrollback + live), host-
    // intercepted like __stats__.
    if (std.mem.eql(u8, line, "__screen__\n") or std.mem.eql(u8, line, "__screen__")) {
        if (ctx.agent.render) |rd| {
            var buf: [64 * 1024]u8 = undefined;
            const n = rd.snapshot(&buf);
            _ = libc.write(c, buf[0..n].ptr, n);
            _ = ctx.meter.bytes_out.fetchAdd(n, .release);
        } else reply(c, "ERR render not enabled\n");
        return;
    }
    // Render streaming: only the live rows that changed since the last __screendiff__
    // (the first call emits the whole screen). Lets the platform follow the screen
    // cheaply by polling.
    if (std.mem.eql(u8, line, "__screendiff__\n") or std.mem.eql(u8, line, "__screendiff__")) {
        if (ctx.agent.render) |rd| {
            var buf: [64 * 1024]u8 = undefined;
            const n = rd.diff(&buf);
            _ = libc.write(c, buf[0..n].ptr, n);
            _ = ctx.meter.bytes_out.fetchAdd(n, .release);
        } else reply(c, "ERR render not enabled\n");
        return;
    }
    // Render (framebuffer): capture the virtio-gpu scanout as a binary PPM.
    if (std.mem.eql(u8, line, "__frame__\n") or std.mem.eql(u8, line, "__frame__")) {
        if (ctx.gpu) |g| {
            const sz = g.frameSize();
            if (sz == 0) {
                reply(c, "ERR no frame\n");
            } else if (ctx.allocator.alloc(u8, sz)) |buf| {
                defer ctx.allocator.free(buf);
                const n = g.frame(buf);
                _ = libc.write(c, buf[0..n].ptr, n);
                _ = ctx.meter.bytes_out.fetchAdd(n, .release);
            } else |_| reply(c, "ERR out of memory\n");
        } else reply(c, "ERR gpu not enabled\n");
        return;
    }
    // Framebuffer streaming: only the tiles changed since the last call (full frame
    // on the first call / after a client reconnects). Same binary-on-the-socket
    // model as __frame__.
    if (std.mem.eql(u8, line, "__framediff__\n") or std.mem.eql(u8, line, "__framediff__")) {
        if (ctx.gpu) |g| {
            const sz = g.shadowSize();
            if (sz == 0) {
                reply(c, "ERR no frame\n");
            } else if (ctx.allocator.alloc(u8, sz * 2)) |buf| { // shadow + out, both <= a full frame
                defer ctx.allocator.free(buf);
                const n = g.frameDiff(buf[0..sz], buf[sz..]);
                _ = libc.write(c, buf[sz..][0..n].ptr, n);
                _ = ctx.meter.bytes_out.fetchAdd(n, .release);
            } else |_| reply(c, "ERR out of memory\n");
        } else reply(c, "ERR gpu not enabled\n");
        return;
    }
    // Lifecycle: on-demand clean teardown (the platform stops a sandbox without
    // killing the process abruptly). Host-intercepted, like __stats__; reply first
    // so the operator sees the ack, then stop (cpu0 returns .shutdown and exits).
    if (std.mem.eql(u8, line, "__shutdown__\n") or std.mem.eql(u8, line, "__shutdown__")) {
        reply(c, "OK shutting down\n");
        std.debug.print("\n[nether] __shutdown__ requested; stopping sandbox\n", .{});
        stopSandbox(ctx.power, ctx.handles, ctx.num_cpus);
        return;
    }
    var id = ctx.agent.conn_id.load(.acquire);
    while (id < 0) {
        _ = usleep(50_000);
        id = ctx.agent.conn_id.load(.acquire);
    }
    // File transfer (host-mediated): the bytes move over vsock with length framing,
    // never through this line-oriented socket, so payloads can be binary/large.
    if (std.mem.startsWith(u8, line, "__put__ ")) {
        controlPut(ctx, c, @intCast(id), line["__put__ ".len..]);
        _ = ctx.meter.commands.fetchAdd(1, .release);
        return;
    }
    if (std.mem.startsWith(u8, line, "__get__ ")) {
        controlGet(ctx, c, @intCast(id), line["__get__ ".len..]);
        _ = ctx.meter.commands.fetchAdd(1, .release);
        return;
    }
    _ = ctx.vsdev.hostSend(@intCast(id), line);
    _ = ctx.meter.commands.fetchAdd(1, .release);
    _ = ctx.meter.bytes_in.fetchAdd(line.len, .release);
}

pub fn controlListener(ctx: *ControlCtx) void {
    const fd = libc.socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        std.debug.print("[control] socket() failed\n", .{});
        return;
    }
    _ = libc.unlink(ctx.path);
    var addr = SockaddrUn{};
    const p = std.mem.span(ctx.path);
    @memcpy(addr.path[0..p.len], p);
    addr.len = @intCast(2 + p.len + 1);
    if (libc.bind(fd, &addr, addr.len) < 0 or libc.listen(fd, 4) < 0) {
        std.debug.print("[control] bind/listen failed on {s}\n", .{ctx.path});
        return;
    }
    std.debug.print("[control] listening on {s}\n", .{ctx.path});
    while (true) {
        const c = libc.accept(fd, null, null);
        if (c < 0) continue;
        ctx.client.store(c, .release);
        if (ctx.agent.render) |rd| rd.resetDiff(); // a fresh client gets a full screen first
        if (ctx.gpu) |g| g.resetFrameDiff(); // ...and a full framebuffer first
        // Line-buffer the client stream so `__stats__` can be intercepted and each
        // command metered; everything else is forwarded verbatim to the agent.
        var buf: [4096]u8 = undefined;
        var len: usize = 0;
        while (true) {
            const r = libc.read(c, buf[len..].ptr, buf.len - len);
            if (r <= 0) break;
            len += @intCast(r);
            var start: usize = 0;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (buf[i] == '\n') {
                    controlCommand(ctx, c, buf[start .. i + 1]);
                    start = i + 1;
                }
            }
            if (start > 0) {
                std.mem.copyForwards(u8, buf[0 .. len - start], buf[start..len]);
                len -= start;
            }
            if (len == buf.len) len = 0; // overlong line: drop
        }
        ctx.client.store(-1, .release);
        _ = libc.close(c);
    }
}

/// Relay the guest agent's reply stream (from the recv pipe) to the current
/// control client.
pub fn controlRelay(ctx: *ControlCtx) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = libc.read(ctx.pipe_r, &buf, buf.len);
        if (n <= 0) return;
        const c = ctx.client.load(.acquire);
        if (c >= 0) {
            _ = libc.write(c, buf[0..@intCast(n)].ptr, @intCast(n));
            _ = ctx.meter.bytes_out.fetchAdd(@intCast(n), .release);
        }
    }
}

pub const AgentStdinCtx = struct { vsdev: *nether.VsockDev, agent: *AgentCtx };

/// I/O thread (agent mode): forward host stdin to the guest agent over vsock.
pub fn agentStdinPump(ctx: *AgentStdinCtx) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = libc.read(0, &buf, buf.len);
        if (n <= 0) return;
        var id = ctx.agent.conn_id.load(.acquire);
        while (id < 0) { // wait until the guest agent has connected
            _ = usleep(50_000);
            id = ctx.agent.conn_id.load(.acquire);
        }
        _ = ctx.vsdev.hostSend(@intCast(id), buf[0..@intCast(n)]);
    }
}
