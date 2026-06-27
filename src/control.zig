//! Control plane: the Unix-domain control socket and the in-guest agent plumbing
//! the platform drives a sandbox through. Command relay, host-mediated file
//! push/pull (__put__/__get__), the __stats__ metering report, and the
//! __shutdown__ lifecycle command all live here, off the boot orchestration in
//! main.zig.

const std = @import("std");
const nether = @import("root.zig");
const hostutil = @import("hostutil.zig");
const Lock = @import("lock.zig").Lock;

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
    // Last control-plane activity (nowMs): a client command or agent output. The
    // idle watchdog reclaims a sandbox that has seen none for idle_timeout_s.
    last_activity_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    /// Mark control-plane activity (resets the idle timer).
    pub fn touch(self: *Metering) void {
        self.last_activity_ms.store(nowMs(), .release);
    }

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

/// Static, per-sandbox capabilities and limits, set once at launch from the
/// resolved nether.conf and reported by the `__info__` control command. Where
/// `__stats__` answers "how much has this sandbox used?", `__info__` answers "what
/// IS this sandbox and what are its limits?" - so a controller can verify what it
/// got and discover capabilities without parsing the config it sent.
pub const SandboxInfo = struct {
    cpus: u32 = 0,
    ram_mb: u64 = 0,
    net: bool = false, // user-mode networking enabled
    firewall: bool = false, // egress firewall enforcing (net on and not net_open)
    gpu: bool = false, // virtio-gpu framebuffer present
    max_runtime_s: u64 = 0, // hard wall-clock cap (0 = unlimited)
    idle_timeout_s: u64 = 0, // idle reclamation (0 = disabled)
    rate_kbps: u64 = 0, // download bandwidth cap (0 = unlimited)
    max_output_bytes: u64 = 0, // per-command output cap (0 = unlimited)

    /// Render the info report (+ the agent's 0x1e<exit>\n framing) into `buf`.
    fn report(self: *const SandboxInfo, buf: []u8) usize {
        const builtin = @import("builtin");
        const backend = if (builtin.os.tag == .macos) "hvf" else "kvm";
        return (std.fmt.bufPrint(buf,
            \\nether sandbox info
            \\backend={s}
            \\arch={s}
            \\cpus={d}
            \\ram_mb={d}
            \\net={s}
            \\firewall={s}
            \\gpu={s}
            \\max_runtime_s={d}
            \\idle_timeout_s={d}
            \\net_rate_kbps={d}
            \\max_output_bytes={d}
            \\{c}0
            \\
        , .{
            backend,
            @tagName(builtin.cpu.arch),
            self.cpus,
            self.ram_mb,
            onOff(self.net),
            onOff(self.firewall),
            onOff(self.gpu),
            self.max_runtime_s,
            self.idle_timeout_s,
            self.rate_kbps,
            self.max_output_bytes,
            @as(u8, 0x1e),
        }) catch return 0).len;
    }
};

fn onOff(b: bool) []const u8 {
    return if (b) "on" else "off";
}

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

// Command audit log (the "observe" pillar, host side): a ring of the shell commands
// the platform ran in the sandbox and their exit codes - the run-history companion to
// slirp's egress log. The command text is captured when forwarded; the exit code is
// scanned out of the agent's 0x1e<code>\n reply trailer. Read via __cmdlog__.
const CMD_LOG_CAP = 128;
const CMD_TEXT_MAX = 120;
const CmdEvent = struct {
    ms: i64 = 0,
    exit: i32 = -1,
    text: [CMD_TEXT_MAX]u8 = undefined,
    text_len: usize = 0,
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
    /// Unified event journal: commands are mirrored here as CMD events.
    journal: ?*nether.Journal = null,
    /// Usage meter, so agent output counts as activity for the idle watchdog.
    meter: ?*Metering = null,
    /// Per-command output cap (govern): bytes of a single command's output relayed
    /// to the control client before the rest is suppressed. The 0x1e<exit>\n trailer
    /// still flows (the client always gets the exit code). 0 = unlimited. Bounds a
    /// runaway or malicious command's output flood (and the billed bytes_out). The
    /// three fields below track the current command's relay state.
    max_output: usize = 0,
    cmd_out_bytes: usize = 0, // body bytes relayed for the current command
    cmd_truncated: bool = false, // emitted the "[output capped]" notice this command
    relay_in_trailer: bool = false, // mid-relay of the trailer (0x1e..\n, always forwarded)

    // Command audit log. cmd_lock is a leaf lock guarding the ring + the pending slot;
    // controlCommand (control thread) sets `pending`, the vsock callback records on the
    // exit trailer - different threads, so the lock is required. Single pending slot:
    // the relay is request/response (the client reads a command's [exit N] before
    // sending the next), so commands don't overlap.
    cmd_lock: Lock = .{},
    cmd_log: [CMD_LOG_CAP]CmdEvent = [_]CmdEvent{.{}} ** CMD_LOG_CAP,
    cmd_head: usize = 0, // next write slot (ring)
    cmd_total: u64 = 0, // lifetime commands (> retained = ring wrapped)
    pend_text: [CMD_TEXT_MAX]u8 = undefined,
    pend_len: usize = 0, // 0 = no command awaiting an exit code
    pend_ms: i64 = 0,
    audit_in_exit: bool = false, // mid-scan of the trailer's exit digits
    audit_exit: [16]u8 = undefined,
    audit_exit_len: usize = 0,

    /// A command was forwarded to the agent: stash it as the pending command awaiting
    /// an exit code. Called on the control thread.
    fn auditForward(a: *AgentCtx, line: []const u8) void {
        // Trim a trailing newline / blanks for a clean record.
        var end = line.len;
        while (end > 0 and (line[end - 1] == '\n' or line[end - 1] == '\r' or line[end - 1] == ' ')) end -= 1;
        const n = @min(end, CMD_TEXT_MAX);
        a.cmd_lock.lock();
        defer a.cmd_lock.unlock();
        @memcpy(a.pend_text[0..n], line[0..n]);
        a.pend_len = n;
        a.pend_ms = nowMs();
    }

    /// Scan agent reply bytes for the 0x1e<exit>\n trailer; on completion, commit the
    /// pending command + its exit code to the ring. Runs on the vsock thread alongside
    /// the raw relay (it only observes, never consumes, the bytes).
    fn auditRecv(a: *AgentCtx, bytes: []const u8) void {
        for (bytes) |b| {
            if (a.audit_in_exit) {
                if (b == '\n') {
                    a.commitPending(std.fmt.parseInt(i32, a.audit_exit[0..a.audit_exit_len], 10) catch -1);
                    a.audit_in_exit = false;
                    a.audit_exit_len = 0;
                } else if (a.audit_exit_len < a.audit_exit.len and b != '\r') {
                    a.audit_exit[a.audit_exit_len] = b;
                    a.audit_exit_len += 1;
                }
            } else if (b == 0x1e) {
                a.audit_in_exit = true;
            }
        }
    }

    /// Relay agent reply bytes to the control client (pipe_w) with a per-command
    /// output cap. Body bytes past `max_output` are dropped (with a one-time notice),
    /// but the trailer (0x1e<exit>\n) is always forwarded so the client still gets the
    /// exit code, and the counter resets on each trailer. Written in forward-spans so
    /// there is no large buffer and it handles any chunk size. Mirrors auditRecv's
    /// 0x1e trailer detection. Only called when max_output > 0.
    fn relayCapped(a: *AgentCtx, bytes: []const u8) void {
        var span: usize = 0; // start of the current run of bytes to forward
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            const b = bytes[i];
            var forward = true;
            if (a.relay_in_trailer) {
                // inside the trailer: always forward
            } else if (b == 0x1e) {
                a.relay_in_trailer = true; // forward the 0x1e too
            } else if (a.cmd_out_bytes >= a.max_output) {
                forward = false; // body past the cap
            } else {
                a.cmd_out_bytes += 1;
            }
            if (forward) {
                if (a.relay_in_trailer and b == '\n') { // trailer complete -> next command
                    a.relay_in_trailer = false;
                    a.cmd_out_bytes = 0;
                    a.cmd_truncated = false;
                }
            } else {
                if (i > span) _ = writeAll(a.pipe_w, bytes[span..i]); // flush forwarded run
                if (!a.cmd_truncated) {
                    a.cmd_truncated = true;
                    _ = writeAll(a.pipe_w, "\n...[output capped]\n");
                }
                span = i + 1; // skip the suppressed byte
            }
        }
        if (bytes.len > span) _ = writeAll(a.pipe_w, bytes[span..bytes.len]);
    }

    fn commitPending(a: *AgentCtx, exit: i32) void {
        a.cmd_lock.lock();
        if (a.pend_len == 0) { // a trailer with no command we tracked (e.g. REPL)
            a.cmd_lock.unlock();
            return;
        }
        var e = CmdEvent{ .ms = a.pend_ms, .exit = exit, .text_len = a.pend_len };
        @memcpy(e.text[0..a.pend_len], a.pend_text[0..a.pend_len]);
        a.cmd_log[a.cmd_head] = e;
        a.cmd_head = (a.cmd_head + 1) % CMD_LOG_CAP;
        a.cmd_total += 1;
        a.pend_len = 0;
        a.cmd_lock.unlock();

        if (a.journal) |j| {
            var b: [CMD_TEXT_MAX + 24]u8 = undefined;
            const s = std.fmt.bufPrint(&b, "exit={d} {s}", .{ exit, e.text[0..e.text_len] }) catch return;
            j.emit(.cmd, s);
        }
    }

    /// Serialize the command audit log oldest-first into `out`:
    ///   "CMDLOG <lifetime-total>\n" then "<ms> exit=<code> <command>\n" per event.
    fn cmdLog(a: *AgentCtx, out: []u8) usize {
        a.cmd_lock.lock();
        defer a.cmd_lock.unlock();
        var n: usize = (std.fmt.bufPrint(out, "CMDLOG {d}\n", .{a.cmd_total}) catch return 0).len;
        const retained: usize = if (a.cmd_total < CMD_LOG_CAP) @intCast(a.cmd_total) else CMD_LOG_CAP;
        const start = if (a.cmd_total < CMD_LOG_CAP) 0 else a.cmd_head;
        var i: usize = 0;
        while (i < retained) : (i += 1) {
            const e = a.cmd_log[(start + i) % CMD_LOG_CAP];
            const line = std.fmt.bufPrint(out[n..], "{d} exit={d} {s}\n", .{ e.ms, e.exit, e.text[0..e.text_len] }) catch break;
            n += line.len;
        }
        return n;
    }

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
            if (a.meter) |m| m.touch();
            if (a.journal) |j| j.emit(.life, "agent connected");
            std.debug.print("[agent] guest agent connected; type commands (they run in the sandbox)\n", .{});
        },
        .recv => |r| if (a.capture.load(.acquire)) |cap| {
            cap.feed(r.bytes); // file transfer in progress: divert the reply
        } else {
            if (a.meter) |m| m.touch(); // agent output: the sandbox is doing work

            if (a.render) |rd| rd.feed(r.bytes); // tee command output into the render screen
            a.auditRecv(r.bytes); // observe exit codes for the command audit log
            if (a.pipe_w >= 0) {
                if (a.max_output == 0) {
                    _ = libc.write(a.pipe_w, r.bytes.ptr, r.bytes.len); // -> relay -> control client
                } else a.relayCapped(r.bytes); // govern: bound a runaway command's output
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
    journal: ?*nether.Journal = null, // unified event timeline, for __events__
    info: SandboxInfo = .{}, // static capabilities/limits, for __info__
    // The primary control client (fd) - the one connection that drives the sandbox
    // and receives the agent relay stream. Additional connections are read-only
    // observers (host-intercepted queries only); -1 = no primary.
    client: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),
    active_clients: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    // File-transfer jail, pinned once at listener start (not per call) so the jail
    // can't move if the process cwd ever changes. Empty until set => fail closed.
    xfer_root_buf: [1024]u8 = undefined,
    xfer_root_len: usize = 0,

    fn xferRoot(self: *const ControlCtx) []const u8 {
        return self.xfer_root_buf[0..self.xfer_root_len];
    }
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

/// True if `path` is `root` itself or lies beneath it. Both must be absolute and
/// canonical (no symlinks/`..`), as returned by realpath. The separator check stops
/// a sibling-prefix escape ("/jail" must not match "/jail-evil").
fn within(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (root.len > 0 and root[root.len - 1] == '/') return true; // root is "/"
    return path.len == root.len or path[root.len] == '/';
}

/// Confine a host transfer path to `root` (the jail, pinned at listener start):
/// canonicalize it and confirm it stays within `root`. For a path being created
/// (`creating`), the file may not exist yet, so resolve its parent directory and
/// re-attach a validated basename. Returns a NUL-terminated absolute path inside
/// the jail in `out`, or null if it escapes or is malformed. An empty `root` (the
/// jail was never established) fails closed.
fn jailedPath(out: *[1024]u8, root: []const u8, req: []const u8, creating: bool) ?[*:0]const u8 {
    if (root.len == 0) return null;
    if (req.len == 0 or req.len + 1 > out.len) return null;

    var rb: [1024]u8 = undefined;
    if (!creating) {
        var tb: [1024]u8 = undefined;
        const reqz = cpath(&tb, req) orelse return null;
        const real_c = libc.realpath(reqz, &rb) orelse return null;
        const real = std.mem.span(real_c);
        if (!within(root, real) or real.len + 1 > out.len) return null;
        @memcpy(out[0..real.len], real);
        out[real.len] = 0;
        return @ptrCast(out);
    }
    // Create: split into dir + basename, resolve the dir, reject a basename that
    // could traverse (it must be a plain name with no separator).
    const slash = std.mem.lastIndexOfScalar(u8, req, '/');
    const dir = if (slash) |s| (if (s == 0) "/" else req[0..s]) else ".";
    const base = if (slash) |s| req[s + 1 ..] else req;
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return null;
    var tb: [1024]u8 = undefined;
    const dirz = cpath(&tb, dir) orelse return null;
    const rdir_c = libc.realpath(dirz, &rb) orelse return null;
    const rdir = std.mem.span(rdir_c);
    if (!within(root, rdir)) return null;
    // rdir + '/' + base + NUL
    const sep: usize = if (rdir.len > 0 and rdir[rdir.len - 1] == '/') 0 else 1;
    if (rdir.len + sep + base.len + 1 > out.len) return null;
    @memcpy(out[0..rdir.len], rdir);
    if (sep == 1) out[rdir.len] = '/';
    @memcpy(out[rdir.len + sep ..][0..base.len], base);
    out[rdir.len + sep + base.len] = 0;
    return @ptrCast(out);
}

/// Host-mediated file push: read the host file and stream it to the guest agent as
/// a __PUT__ request. `args` = "<hostpath> <guestpath>".
fn controlPut(ctx: *ControlCtx, c: c_int, id: u16, args: []const u8) void {
    const sp = std.mem.indexOfScalar(u8, args, ' ') orelse return reply(c, "ERR bad __put__ (need <hostpath> <guestpath>)\n");
    const hostpath = std.mem.trim(u8, args[0..sp], " \t\r\n");
    const guestpath = std.mem.trim(u8, args[sp + 1 ..], " \t\r\n");
    var pb: [1024]u8 = undefined;
    const hp = jailedPath(&pb, ctx.xferRoot(), hostpath, false) orelse return reply(c, "ERR host path outside transfer dir\n");
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
    const hp = jailedPath(&pb, ctx.xferRoot(), hostpath, true) orelse return reply(c, "ERR host path outside transfer dir\n");
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
    _ = writeAll(c, msg);
}

/// Send one command line to the guest agent (waiting for it to connect), counting
/// it for metering. `__stats__` and `__shutdown__` are intercepted here and
/// answered by the host without touching the guest.
fn controlCommand(ctx: *ControlCtx, c: c_int, line: []const u8, is_primary: bool) void {
    ctx.meter.touch(); // any client command counts as activity (resets the idle timer)
    if (std.mem.eql(u8, line, "__stats__\n") or std.mem.eql(u8, line, "__stats__")) {
        var rep: [512]u8 = undefined;
        const n = ctx.meter.report(&rep);
        _ = writeAll(c, rep[0..n]);
        _ = ctx.meter.bytes_out.fetchAdd(n, .release);
        return;
    }
    // Introspection: the sandbox's static capabilities + limits (what it IS, vs
    // __stats__'s what it has used). Host-intercepted.
    if (std.mem.eql(u8, line, "__info__\n") or std.mem.eql(u8, line, "__info__")) {
        var rep: [512]u8 = undefined;
        const n = ctx.info.report(&rep);
        _ = writeAll(c, rep[0..n]);
        _ = ctx.meter.bytes_out.fetchAdd(n, .release);
        return;
    }
    // Observe: the egress audit log - every destination the sandbox tried to reach
    // (new TCP connections / UDP flows) with the firewall's verdict. Host-intercepted.
    if (std.mem.eql(u8, line, "__netlog__\n") or std.mem.eql(u8, line, "__netlog__")) {
        if (ctx.meter.net) |s| {
            var buf: [16384]u8 = undefined;
            const n = s.netLog(&buf);
            _ = writeAll(c, buf[0..n]);
            _ = ctx.meter.bytes_out.fetchAdd(n, .release);
        } else reply(c, "ERR net not enabled\n");
        return;
    }
    // Observe: the command audit log - every shell command the platform ran in the
    // sandbox and its exit code. Host-intercepted.
    if (std.mem.eql(u8, line, "__cmdlog__\n") or std.mem.eql(u8, line, "__cmdlog__")) {
        var buf: [16384]u8 = undefined;
        const n = ctx.agent.cmdLog(&buf);
        _ = writeAll(c, buf[0..n]);
        _ = ctx.meter.bytes_out.fetchAdd(n, .release);
        return;
    }
    // Observe: the unified event timeline (commands + network + lifecycle), polled
    // with a cursor. "__events__" dumps the retained ring; "__events__ <seq>" returns
    // only events after that sequence number (the previous EVENTS header's value).
    if (std.mem.eql(u8, line, "__events__\n") or std.mem.eql(u8, line, "__events__") or std.mem.startsWith(u8, line, "__events__ ")) {
        if (ctx.journal) |j| {
            const after: u64 = blk: {
                if (std.mem.startsWith(u8, line, "__events__ ")) {
                    const arg = std.mem.trim(u8, line["__events__ ".len..], " \r\n");
                    break :blk std.fmt.parseInt(u64, arg, 10) catch 0;
                }
                break :blk 0;
            };
            // Sized from the journal's own bound so a full-ring dump never truncates
            // (a truncated body would drop the newest events while the header still
            // advertises the full seq, silently losing them for an incremental client).
            var buf: [nether.audit.SERIALIZE_MAX]u8 = undefined;
            const n = j.since(&buf, after);
            _ = writeAll(c, buf[0..n]);
            _ = ctx.meter.bytes_out.fetchAdd(n, .release);
        } else reply(c, "ERR journal not enabled\n");
        return;
    }
    // Render: full snapshot of the sandbox terminal (scrollback + live), host-
    // intercepted like __stats__.
    if (std.mem.eql(u8, line, "__screen__\n") or std.mem.eql(u8, line, "__screen__")) {
        if (ctx.agent.render) |rd| {
            var buf: [64 * 1024]u8 = undefined;
            const n = rd.snapshot(&buf);
            _ = writeAll(c, buf[0..n]);
            _ = ctx.meter.bytes_out.fetchAdd(n, .release);
        } else reply(c, "ERR render not enabled\n");
        return;
    }
    // Render streaming: only the live rows that changed since the last __screendiff__
    // (the first call emits the whole screen). Lets the platform follow the screen
    // cheaply by polling.
    if (std.mem.eql(u8, line, "__screendiff__\n") or std.mem.eql(u8, line, "__screendiff__")) {
        if (!is_primary) return reply(c, "ERR __screendiff__ is primary-only (per-client diff state)\n");
        if (ctx.agent.render) |rd| {
            var buf: [64 * 1024]u8 = undefined;
            const n = rd.diff(&buf);
            _ = writeAll(c, buf[0..n]);
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
                _ = writeAll(c, buf[0..n]);
                _ = ctx.meter.bytes_out.fetchAdd(n, .release);
            } else |_| reply(c, "ERR out of memory\n");
        } else reply(c, "ERR gpu not enabled\n");
        return;
    }
    // Framebuffer streaming: only the tiles changed since the last call (full frame
    // on the first call / after a client reconnects). Same binary-on-the-socket
    // model as __frame__.
    if (std.mem.eql(u8, line, "__framediff__\n") or std.mem.eql(u8, line, "__framediff__")) {
        if (!is_primary) return reply(c, "ERR __framediff__ is primary-only (per-client diff state)\n");
        if (ctx.gpu) |g| {
            const sz = g.shadowSize();
            if (sz == 0) {
                reply(c, "ERR no frame\n");
            } else if (ctx.allocator.alloc(u8, sz * 2)) |buf| { // shadow + out, both <= a full frame
                defer ctx.allocator.free(buf);
                const n = g.frameDiff(buf[0..sz], buf[sz..]);
                _ = writeAll(c, buf[sz..][0..n]);
                _ = ctx.meter.bytes_out.fetchAdd(n, .release);
            } else |_| reply(c, "ERR out of memory\n");
        } else reply(c, "ERR gpu not enabled\n");
        return;
    }
    // Everything below this point drives or tears down the sandbox (shutdown, file
    // transfer, and relaying a command to the agent). Only the primary client may do
    // so; observers are read-only and limited to the host-intercepted queries above.
    if (!is_primary) {
        reply(c, "ERR read-only observer; only the primary control client may drive the sandbox\n");
        return;
    }
    // Lifecycle: on-demand clean teardown (the platform stops a sandbox without
    // killing the process abruptly). Host-intercepted, like __stats__; reply first
    // so the operator sees the ack, then stop (cpu0 returns .shutdown and exits).
    if (std.mem.eql(u8, line, "__shutdown__\n") or std.mem.eql(u8, line, "__shutdown__")) {
        if (ctx.journal) |j| j.emit(.life, "shutdown requested");
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
    ctx.agent.auditForward(line); // record the command, awaiting its exit code
    _ = ctx.vsdev.hostSend(@intCast(id), line);
    _ = ctx.meter.commands.fetchAdd(1, .release);
    _ = ctx.meter.bytes_in.fetchAdd(line.len, .release);
}

/// Concurrent control connections allowed: the platform's primary driver plus a
/// handful of read-only observers. The socket is owner-uid-gated, so this only
/// bounds an accidental fan-out, not an attacker.
const MAX_CLIENTS: u32 = 8;

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
    // The control socket grants full control of the VM (run commands in the guest,
    // shut down, pull screen/frame snapshots, transfer host files). The default
    // path lives in world-traversable /tmp, so restrict it to the owner: tighten the
    // socket file to 0600 and reject any peer whose uid is not ours. We just
    // unlink+bind'd, so there is no pre-existing file to inherit looser perms from.
    if (libc.fchmod(fd, 0o600) != 0) std.debug.print("[control] warning: fchmod 0600 on socket failed\n", .{});
    const owner_uid = libc.getuid();
    // Pin the file-transfer jail once, here, to the launch directory. Done at
    // listener start (not per __put__/__get__) so the jail can't follow a later
    // cwd change. If realpath fails, the root stays empty and transfers fail closed.
    if (libc.realpath(".", &ctx.xfer_root_buf)) |r| ctx.xfer_root_len = std.mem.span(r).len;
    std.debug.print("[control] listening on {s}\n", .{ctx.path});
    while (true) {
        const c = libc.accept(fd, null, null);
        if (c < 0) continue;
        // Authoritative gate: only the owning uid may drive the control plane,
        // even if the socket perms were somehow loosened (race, remount, umask).
        var euid: u32 = 0;
        var egid: u32 = 0;
        if (libc.getpeereid(c, &euid, &egid) != 0 or euid != owner_uid) {
            std.debug.print("[control] rejected connection from uid {d} (owner {d})\n", .{ euid, owner_uid });
            _ = libc.close(c);
            continue;
        }
        // Bound concurrent connections (the platform's driver + a few observers). The
        // socket is owner-uid-gated, so this just caps an accidental fan-out.
        if (ctx.active_clients.fetchAdd(1, .acq_rel) >= MAX_CLIENTS) {
            _ = ctx.active_clients.fetchSub(1, .release);
            reply(c, "ERR too many control clients\n");
            _ = libc.close(c);
            continue;
        }
        // One thread per connection: an observer can poll while the primary's command
        // output streams (they can't share a socket without interleaving bytes).
        if (std.Thread.spawn(.{}, clientThread, .{ ctx, c })) |t| {
            t.detach();
        } else |_| {
            _ = ctx.active_clients.fetchSub(1, .release);
            _ = libc.close(c);
        }
    }
}

/// Serve one control connection. The first connection to claim the primary slot
/// drives the sandbox and receives the agent relay stream; the rest are read-only
/// observers limited to the host-intercepted queries - so the platform can follow
/// events/stats/the screen on a side connection while a long command streams on the
/// primary (a single socket can't carry both without interleaving). Detached thread.
fn clientThread(ctx: *ControlCtx, c: c_int) void {
    defer _ = libc.close(c);
    defer _ = ctx.active_clients.fetchSub(1, .release);
    // Claim the primary slot if it is free; otherwise serve as an observer.
    const is_primary = ctx.client.cmpxchgStrong(-1, c, .acq_rel, .acquire) == null;
    defer if (is_primary) ctx.client.store(-1, .release);
    if (is_primary) {
        if (ctx.agent.render) |rd| rd.resetDiff(); // a fresh primary gets a full screen first
        if (ctx.gpu) |g| g.resetFrameDiff(); // ...and a full framebuffer first
    }
    // Line-buffer the client stream so `__stats__` etc. are intercepted per line.
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    var skipping = false; // discarding the tail of an overlong line until its '\n'
    while (true) {
        const r = libc.read(c, buf[len..].ptr, buf.len - len);
        if (r <= 0) break;
        len += @intCast(r);
        // Resync after an overlong line: drop everything up to and including the next
        // newline, then resume normal parsing on whatever follows.
        if (skipping) {
            if (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |nl| {
                std.mem.copyForwards(u8, buf[0 .. len - (nl + 1)], buf[nl + 1 .. len]);
                len -= nl + 1;
                skipping = false;
            } else {
                len = 0; // still no newline; keep discarding
                continue;
            }
        }
        var start: usize = 0;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (buf[i] == '\n') {
                controlCommand(ctx, c, buf[start .. i + 1], is_primary);
                start = i + 1;
            }
        }
        if (start > 0) {
            std.mem.copyForwards(u8, buf[0 .. len - start], buf[start..len]);
            len -= start;
        }
        // A full buffer with no newline is an overlong command: reject it explicitly
        // (rather than silently dropping) and skip its remainder so the tail is never
        // misparsed as a fresh command.
        if (len == buf.len) {
            reply(c, "ERR line too long (max 4096 bytes)\n");
            len = 0;
            skipping = true;
        }
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

// --- tests -----------------------------------------------------------------
const testing = std.testing;

test "output cap suppresses body past the limit but always forwards the trailer" {
    var fds: [2]c_int = undefined;
    try testing.expect(libc.pipe(&fds) == 0);
    defer _ = libc.close(fds[0]);
    defer _ = libc.close(fds[1]);
    var a = AgentCtx{ .pipe_w = fds[1], .max_output = 5 };
    a.relayCapped("AAAAAAAAAAAAAAAAAAAA\x1e0\n"); // 20 body bytes + trailer (exit 0)

    var buf: [256]u8 = undefined;
    const n = libc.read(fds[0], &buf, buf.len);
    try testing.expect(n > 0);
    const out = buf[0..@intCast(n)];
    try testing.expect(std.mem.startsWith(u8, out, "AAAAA")); // first 5 forwarded
    try testing.expect(std.mem.indexOf(u8, out, "[output capped]") != null);
    try testing.expect(std.mem.endsWith(u8, out, "\x1e0\n")); // exit frame intact
    var as: usize = 0;
    for (out) |c| {
        if (c == 'A') as += 1;
    }
    try testing.expectEqual(@as(usize, 5), as); // body capped at exactly 5

    // A second command resets the cap (counter cleared on the trailer).
    a.relayCapped("BBB\x1e1\n");
    const n2 = libc.read(fds[0], &buf, buf.len);
    const out2 = buf[0..@intCast(n2)];
    try testing.expect(std.mem.indexOf(u8, out2, "BBB") != null); // under cap -> all forwarded
    try testing.expect(std.mem.indexOf(u8, out2, "capped") == null);
    try testing.expect(std.mem.endsWith(u8, out2, "\x1e1\n"));
}

test "sandbox info report renders capabilities and limits with the exit frame" {
    const info = SandboxInfo{
        .cpus = 4,
        .ram_mb = 512,
        .net = true,
        .firewall = true,
        .gpu = false,
        .max_runtime_s = 60,
        .idle_timeout_s = 8,
        .rate_kbps = 0,
    };
    var buf: [512]u8 = undefined;
    const out = buf[0..info.report(&buf)];
    try testing.expect(std.mem.indexOf(u8, out, "cpus=4\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ram_mb=512\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "net=on\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "firewall=on\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "gpu=off\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "max_runtime_s=60\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "idle_timeout_s=8\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "net_rate_kbps=0\n") != null);
    try testing.expect(std.mem.indexOfScalar(u8, out, 0x1e) != null); // exit frame
}

test "transfer jail containment check rejects escapes and sibling-prefixes" {
    // Inside the jail.
    try testing.expect(within("/jail", "/jail")); // the root itself
    try testing.expect(within("/jail", "/jail/file"));
    try testing.expect(within("/jail", "/jail/sub/deep.txt"));
    try testing.expect(within("/", "/anything")); // root "/" contains all
    // Escapes.
    try testing.expect(!within("/jail", "/etc/passwd"));
    try testing.expect(!within("/jail", "/jail-evil/x")); // sibling-prefix, not a child
    try testing.expect(!within("/jail", "/jailx")); // prefix without separator
    try testing.expect(!within("/jail/sub", "/jail/other"));
}

test "command audit log records commands with exit codes oldest-first" {
    var a = AgentCtx{};
    a.auditForward("echo hi\n");
    a.auditRecv("hi\n\x1e0\n"); // command output, then the trailer (exit 0)
    a.auditForward("false\n");
    a.auditRecv("\x1e1\n"); // no output, exit 1
    a.auditForward("grep x f\n");
    a.auditRecv("\x1e2\n");

    var buf: [4096]u8 = undefined;
    const out = buf[0..a.cmdLog(&buf)];
    try testing.expect(std.mem.startsWith(u8, out, "CMDLOG 3\n"));
    try testing.expect(std.mem.indexOf(u8, out, "exit=0 echo hi\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "exit=1 false\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "exit=2 grep x f\n") != null);
    // oldest-first ordering
    try testing.expect(std.mem.indexOf(u8, out, "echo hi").? < std.mem.indexOf(u8, out, "false").?);
}

test "command audit log handles a trailer split across reads" {
    var a = AgentCtx{};
    a.auditForward("cmd\n");
    a.auditRecv("partial output\x1e1"); // separator + first digit, newline not yet arrived
    a.auditRecv("2\n"); // continues: exit code is "12"
    var buf: [256]u8 = undefined;
    const out = buf[0..a.cmdLog(&buf)];
    try testing.expect(std.mem.indexOf(u8, out, "exit=12 cmd\n") != null);
}

test "command audit log ring wraps and keeps the lifetime total" {
    var a = AgentCtx{};
    var i: u32 = 0;
    while (i < CMD_LOG_CAP + 3) : (i += 1) {
        var nb: [32]u8 = undefined;
        a.auditForward(std.fmt.bufPrint(&nb, "cmd{d}\n", .{i}) catch unreachable);
        a.auditRecv("\x1e0\n");
    }
    var buf: [16384]u8 = undefined;
    const out = buf[0..a.cmdLog(&buf)];
    try testing.expect(std.mem.startsWith(u8, out, "CMDLOG 131\n")); // lifetime survives the wrap
    try testing.expect(std.mem.indexOf(u8, out, " cmd0\n") == null); // earliest dropped
    try testing.expect(std.mem.indexOf(u8, out, " cmd130\n") != null); // newest retained
}
