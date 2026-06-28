//! Control plane: the Unix-domain control socket and the in-guest agent plumbing
//! the platform drives a sandbox through. Command relay, host-mediated file
//! push/pull (__put__/__get__), the __stats__ metering report, and the
//! __shutdown__ lifecycle command all live here, off the boot orchestration in
//! main.zig.

const std = @import("std");
const nether = @import("../root.zig");
const platform = @import("platform.zig");
const hostutil = @import("../common/hostutil.zig");
const Lock = @import("../common/lock.zig").Lock;

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
            \\cpu_ms={d}
            \\ram_mb={d}
            \\mem_peak_mb={d}
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
            hostutil.processCpuMs(),
            self.ram_mb,
            hostutil.processMaxRssMb(),
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

    /// One-line, machine-readable usage summary for the teardown "bill" - the same
    /// numbers as `__stats__` (compute, memory, I/O, network) but compact and emitted
    /// unconditionally at session end, so the platform always captures a final
    /// accounting even if the client never polled `__stats__`.
    pub fn summary(self: *Metering, buf: []u8) []const u8 {
        const net_tx = if (self.net) |s| s.tx_bytes.load(.monotonic) else 0;
        const net_rx = if (self.net) |s| s.rx_bytes.load(.monotonic) else 0;
        const net_blocked = if (self.net) |s| s.blocked_count.load(.monotonic) else 0;
        return std.fmt.bufPrint(buf, "uptime_ms={d} cpu_ms={d} mem_peak_mb={d} ram_mb={d} cpus={d} commands={d} bytes_in={d} bytes_out={d} net_tx={d} net_rx={d} net_blocked={d}", .{
            nowMs() - self.start_ms,
            hostutil.processCpuMs(),
            hostutil.processMaxRssMb(),
            self.ram_mb,
            self.cpus,
            self.commands.load(.acquire),
            self.bytes_in.load(.acquire),
            self.bytes_out.load(.acquire),
            net_tx,
            net_rx,
            net_blocked,
        }) catch buf[0..0];
    }
};

/// Control-protocol version, surfaced in `__info__` (`proto_version=`). Bump on any
/// breaking change to the command set or wire format so an integrating client (swerver)
/// can check compatibility before driving the sandbox. The command list itself is
/// discoverable at runtime via `__help__` and documented in docs/control-protocol.md.
pub const PROTO_VERSION = 1;

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
    max_cpu_s: u64 = 0, // hard CPU-time cap (0 = unlimited)
    idle_timeout_s: u64 = 0, // idle reclamation (0 = disabled)
    rate_kbps: u64 = 0, // download bandwidth cap (0 = unlimited)
    max_output_bytes: u64 = 0, // per-command output cap (0 = unlimited)

    /// Render the info report (+ the agent's 0x1e<exit>\n framing) into `buf`.
    fn report(self: *const SandboxInfo, buf: []u8) usize {
        const builtin = @import("builtin");
        const backend = if (builtin.os.tag == .macos) "hvf" else "kvm";
        return (std.fmt.bufPrint(buf,
            \\nether sandbox info
            \\proto_version={d}
            \\backend={s}
            \\arch={s}
            \\cpus={d}
            \\ram_mb={d}
            \\net={s}
            \\firewall={s}
            \\gpu={s}
            \\max_runtime_s={d}
            \\max_cpu_s={d}
            \\idle_timeout_s={d}
            \\net_rate_kbps={d}
            \\max_output_bytes={d}
            \\{c}0
            \\
        , .{
            PROTO_VERSION,
            backend,
            @tagName(builtin.cpu.arch),
            self.cpus,
            self.ram_mb,
            onOff(self.net),
            onOff(self.firewall),
            onOff(self.gpu),
            self.max_runtime_s,
            self.max_cpu_s,
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

/// The core observe/meter/run state every sandbox has: the event Journal, the usage
/// Meter, and the AgentCtx, with the agent cross-wired to the journal + meter. Both
/// boot paths construct it the same way via `init`. The cross-pointers are to its own
/// fields, so it must be initialized in place and not moved after - declare it in the
/// boot frame, call init, then hand out &core.agent / &core.journal / &core.meter.
pub const Core = struct {
    journal: nether.Journal = .{},
    meter: Metering = .{},
    agent: AgentCtx = .{},

    /// Wire the core state in place and emit the boot lifecycle event.
    pub fn init(self: *Core, ram_mb: u64, cpus: u32, max_output: usize) void {
        self.meter = .{ .start_ms = nowMs(), .ram_mb = ram_mb, .cpus = cpus };
        self.agent.journal = &self.journal;
        self.agent.meter = &self.meter; // agent output is activity for the idle watchdog
        self.agent.max_output = max_output; // govern: per-command output cap
        self.journal.emit(.life, "boot");
    }

    /// Emit the final usage record at sandbox teardown: print it (the platform that
    /// spawned nether reads its stdout/stderr) and mirror it into the journal as a LIFE
    /// event. Called once when the run loop returns - for ANY reason (guest shutdown,
    /// runtime/cpu/idle budget, __shutdown__) - so every session ends with a guaranteed,
    /// machine-readable bill, closing the meter -> settlement loop.
    pub fn finalUsage(self: *Core, reason: []const u8) void {
        var buf: [256]u8 = undefined;
        const line = self.meter.summary(&buf);
        std.debug.print("[nether] final usage (reason={s}): {s}\n", .{ reason, line });
        var jbuf: [320]u8 = undefined;
        const ev = std.fmt.bufPrint(&jbuf, "session ended (reason={s}): {s}", .{ reason, line }) catch return;
        self.journal.emit(.life, ev);
    }
};

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
    cpu_ms: i64 = 0, // process CPU consumed while this command ran (delta over its lifetime)
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
    pend_cpu_ms: i64 = 0, // process CPU at command start, for the per-command delta
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
        a.pend_cpu_ms = @intCast(hostutil.processCpuMs());
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
        // CPU consumed since the command was forwarded. Process-wide (the guest's vCPU
        // threads dominate while a request/response command runs and the host is idle),
        // so it's a close attribution for compute-bound commands; clamped at 0.
        const cpu_delta = @max(0, @as(i64, @intCast(hostutil.processCpuMs())) - a.pend_cpu_ms);
        var e = CmdEvent{ .ms = a.pend_ms, .exit = exit, .cpu_ms = cpu_delta, .text_len = a.pend_len };
        @memcpy(e.text[0..a.pend_len], a.pend_text[0..a.pend_len]);
        a.cmd_log[a.cmd_head] = e;
        a.cmd_head = (a.cmd_head + 1) % CMD_LOG_CAP;
        a.cmd_total += 1;
        a.pend_len = 0;
        a.cmd_lock.unlock();

        if (a.journal) |j| {
            var b: [CMD_TEXT_MAX + 40]u8 = undefined;
            const s = std.fmt.bufPrint(&b, "exit={d} cpu_ms={d} {s}", .{ exit, cpu_delta, e.text[0..e.text_len] }) catch return;
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
            const line = std.fmt.bufPrint(out[n..], "{d} exit={d} cpu_ms={d} {s}\n", .{ e.ms, e.exit, e.cpu_ms, e.text[0..e.text_len] }) catch break;
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
    stop: platform.Stop, // backend-agnostic guest stop, for the __shutdown__ command
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
    // Introspection: the command set itself, so a client can discover the protocol at
    // runtime (paired with __info__'s proto_version and docs/control-protocol.md).
    // Read-only; available to observers. Ends with the 0x1e exit frame like __info__.
    if (std.mem.eql(u8, line, "__help__\n") or std.mem.eql(u8, line, "__help__")) {
        const help =
            "nether control protocol v" ++ std.fmt.comptimePrint("{d}", .{PROTO_VERSION}) ++ "\n" ++
            "# read-only (any client):\n" ++
            "__info__         sandbox capabilities + limits (incl. proto_version)\n" ++
            "__stats__        usage counters: cpu_ms, mem_peak_mb, commands, bytes, net\n" ++
            "__events__ [seq] unified event timeline (cmd/net/lifecycle); cursor-polled\n" ++
            "__cmdlog__       command audit log (per-command exit + cpu_ms)\n" ++
            "__netlog__       egress audit log (dest + firewall verdict)\n" ++
            "__screen__       terminal snapshot (scrollback + live)\n" ++
            "__screendiff__   terminal changed rows since last call (primary-only)\n" ++
            "__frame__        framebuffer as a binary PPM\n" ++
            "__framediff__    framebuffer changed tiles since last call (primary-only)\n" ++
            "__help__         this list\n" ++
            "# primary client only (drive the sandbox):\n" ++
            "__shutdown__     clean teardown\n" ++
            "__put__ <h> <g>  push host file -> guest path\n" ++
            "__get__ <g> <h>  pull guest file -> host path\n" ++
            "<other>          run as a shell command in the guest (framed reply + [exit N])\n" ++
            "\x1e0\n";
        _ = writeAll(c, help);
        _ = ctx.meter.bytes_out.fetchAdd(help.len, .release);
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
        ctx.stop.call();
        return;
    }
    // Reserved namespace: `__name__` is Nether's control-command space. A line that
    // looks like one but matched none above (a typo, or a client mistaking a guest
    // verb for a control command) is a protocol error - reject it loudly instead of
    // forwarding "__whatever__" to the guest, where it would run as a shell command
    // and fail confusingly (exit 127). __put__/__get__ are valid and handled below.
    if (std.mem.startsWith(u8, line, "__") and
        !std.mem.startsWith(u8, line, "__put__ ") and
        !std.mem.startsWith(u8, line, "__get__ "))
    {
        return reply(c, "ERR unknown command (see __help__); __ is reserved for control commands\n");
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

/// Inputs to wire one sandbox's control socket, supplied by the boot path.
pub const ControlOpts = struct {
    vsdev: *nether.VsockDev,
    agent: *AgentCtx,
    meter: *Metering,
    journal: *nether.Journal,
    gpu: ?*nether.VirtioGpu = null,
    stop: platform.Stop, // backend-agnostic guest stop for __shutdown__
    info: SandboxInfo,
    path: [*:0]const u8,
    allocator: std.mem.Allocator,
};

/// Open the control socket and start the listener + relay threads. `ctl` is filled
/// in place and held by the detached threads, so it must be stable storage in the
/// caller's frame (the boot frame). The agent's reply pipe is created here and wired
/// into both the agent (pipe_w) and the relay (pipe_r). Shared by both boot paths.
pub fn startControl(ctl: *ControlCtx, o: ControlOpts) void {
    var pipe: [2]c_int = undefined;
    if (libc.pipe(&pipe) != 0) {
        std.debug.print("[control] pipe() failed; control socket disabled\n", .{});
        return;
    }
    o.agent.pipe_w = pipe[1];
    ctl.* = .{
        .vsdev = o.vsdev,
        .agent = o.agent,
        .meter = o.meter,
        .path = o.path,
        .pipe_r = pipe[0],
        .allocator = o.allocator,
        .stop = o.stop,
        .gpu = o.gpu,
        .journal = o.journal,
        .info = o.info,
    };
    if (std.Thread.spawn(.{}, controlListener, .{ctl})) |t| t.detach() else |_| {}
    if (std.Thread.spawn(.{}, controlRelay, .{ctl})) |t| t.detach() else |_| {}
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
    // `path` is at offset 2 on both OSes; the address length is that + the path + NUL.
    // Only BSD/macOS has the leading sun_len byte to populate.
    const addr_len: u32 = @intCast(@offsetOf(SockaddrUn, "path") + p.len + 1);
    if (@hasField(SockaddrUn, "len")) addr.len = @intCast(addr_len);
    if (libc.bind(fd, &addr, addr_len) < 0 or libc.listen(fd, 4) < 0) {
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
        // Authoritative gate: only the owning uid may drive the control plane, even if
        // the socket perms were somehow loosened (race, remount, umask). Portable peer
        // check: getpeereid on macOS, SO_PEERCRED on Linux.
        const peer = hostutil.peerUid(c);
        if (peer == null or peer.? != owner_uid) {
            std.debug.print("[control] rejected connection from uid {?d} (owner {d})\n", .{ peer, owner_uid });
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

test "peerUid returns the owner uid for a local socketpair" {
    var fds: [2]c_int = undefined;
    // Both ends of an AF_UNIX socketpair are this process, so the peer uid == ours.
    if (libc.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) != 0) return error.SkipZigTest;
    defer _ = libc.close(fds[0]);
    defer _ = libc.close(fds[1]);
    const peer = hostutil.peerUid(fds[0]);
    try testing.expect(peer != null);
    try testing.expectEqual(libc.getuid(), peer.?);
}

// The control protocol is the integration contract (docs/control-protocol.md). This
// pins the host-intercepted surface a client like swerver builds against: the replies,
// the proto version, and the primary-vs-observer gate. It drives controlCommand over a
// socketpair (no live guest needed - none of the tested commands touch the guest path).
test "control protocol: introspection replies, versioning, observer gating" {
    var core = Core{};
    core.init(512, 4, 0); // ram_mb, cpus, max_output; emits the "boot" journal event
    var dummy_vsdev: nether.VsockDev = undefined; // host-intercepted cmds never deref it

    const Spy = struct {
        stopped: bool = false,
        fn stop(p: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p));
            self.stopped = true;
        }
    };
    var spy = Spy{};
    var ctx = ControlCtx{
        .vsdev = &dummy_vsdev,
        .agent = &core.agent,
        .meter = &core.meter,
        .path = "/tmp/nether-test-unused.sock",
        .pipe_r = -1,
        .allocator = testing.allocator,
        .stop = .{ .ctx = &spy, .func = Spy.stop },
        .journal = &core.journal,
        .info = .{ .cpus = 4, .ram_mb = 512 },
    };

    var fds: [2]c_int = undefined;
    if (libc.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) != 0) return error.SkipZigTest;
    defer _ = libc.close(fds[0]);
    defer _ = libc.close(fds[1]);
    const w = fds[1];
    var rbuf: [8192]u8 = undefined;
    // controlCommand writes the whole (small) reply synchronously before we read, so a
    // single read returns it all.
    const drain = struct {
        fn d(fd: c_int, b: []u8) []const u8 {
            const n = libc.read(fd, b.ptr, b.len);
            return if (n > 0) b[0..@intCast(n)] else b[0..0];
        }
    }.d;

    // __info__: versioned capabilities.
    controlCommand(&ctx, w, "__info__\n", true);
    try testing.expect(std.mem.indexOf(u8, drain(fds[0], &rbuf), "proto_version=1") != null);

    // __help__: discoverable command list with the version banner.
    controlCommand(&ctx, w, "__help__\n", true);
    {
        const out = drain(fds[0], &rbuf);
        try testing.expect(std.mem.indexOf(u8, out, "control protocol v1") != null);
        try testing.expect(std.mem.indexOf(u8, out, "__shutdown__") != null);
        try testing.expect(std.mem.indexOf(u8, out, "__put__") != null);
    }

    // __stats__: the metered dimensions.
    controlCommand(&ctx, w, "__stats__\n", true);
    try testing.expect(std.mem.indexOf(u8, drain(fds[0], &rbuf), "cpu_ms=") != null);

    // __events__: the journal's boot lifecycle event is visible.
    controlCommand(&ctx, w, "__events__\n", true);
    try testing.expect(std.mem.indexOf(u8, drain(fds[0], &rbuf), "LIFE boot") != null);

    // Reserved namespace: an unknown __verb__ is rejected loudly (not forwarded to the
    // guest shell). Tested as primary so it passes the gate and reaches the check.
    controlCommand(&ctx, w, "__bogus__\n", true);
    try testing.expect(std.mem.indexOf(u8, drain(fds[0], &rbuf), "ERR unknown command") != null);

    // Observer gate: a non-primary client cannot drive the sandbox; stop must NOT fire.
    controlCommand(&ctx, w, "__shutdown__\n", false);
    try testing.expect(std.mem.indexOf(u8, drain(fds[0], &rbuf), "ERR read-only observer") != null);
    try testing.expect(!spy.stopped);

    // Primary may: acked, and the injected stop fires exactly once here.
    controlCommand(&ctx, w, "__shutdown__\n", true);
    try testing.expect(std.mem.indexOf(u8, drain(fds[0], &rbuf), "OK shutting down") != null);
    try testing.expect(spy.stopped);
}

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
    try testing.expect(std.mem.indexOf(u8, out, "proto_version=") != null); // versioned protocol
    try testing.expect(std.mem.indexOf(u8, out, "cpus=4\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ram_mb=512\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "net=on\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "firewall=on\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "gpu=off\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "max_runtime_s=60\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "max_cpu_s=0\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "idle_timeout_s=8\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "net_rate_kbps=0\n") != null);
    try testing.expect(std.mem.indexOfScalar(u8, out, 0x1e) != null); // exit frame
}

test "metering summary is a one-line bill carrying compute, memory, and I/O" {
    var m = Metering{ .start_ms = nowMs(), .ram_mb = 512, .cpus = 2 };
    m.commands.store(3, .release);
    m.bytes_in.store(27, .release);
    m.bytes_out.store(287, .release);
    var buf: [256]u8 = undefined;
    const line = m.summary(&buf);
    // Compact (single line) and carries the metered dimensions.
    try testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
    try testing.expect(std.mem.indexOf(u8, line, "cpu_ms=") != null);
    try testing.expect(std.mem.indexOf(u8, line, "mem_peak_mb=") != null);
    try testing.expect(std.mem.indexOf(u8, line, "ram_mb=512") != null);
    try testing.expect(std.mem.indexOf(u8, line, "commands=3") != null);
    try testing.expect(std.mem.indexOf(u8, line, "bytes_out=287") != null);
    try testing.expect(std.mem.indexOf(u8, line, "net_tx=0") != null); // net=null -> zeros
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

test "transfer jail (jailedPath) confines real paths, incl symlink escapes" {
    const c = struct {
        extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
        extern "c" fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) c_int;
        extern "c" fn rmdir(path: [*:0]const u8) c_int;
    };
    const jail = "/tmp/nether-jailtest";
    const inside = jail ++ "/inside.txt";
    const escape = jail ++ "/escape"; // a symlink pointing OUT of the jail
    // Clean any leftovers, then build the jail fresh.
    _ = libc.unlink(inside);
    _ = libc.unlink(escape);
    _ = c.rmdir(jail);
    if (c.mkdir(jail, 0o700) != 0) return error.SkipZigTest;
    defer {
        _ = libc.unlink(inside);
        _ = libc.unlink(escape);
        _ = c.rmdir(jail);
    }
    const O_CREAT = 0x0200;
    const O_WRONLY = 0x0001;
    const fd = libc.open(inside, O_CREAT | O_WRONLY, @as(c_int, 0o600));
    if (fd >= 0) _ = libc.close(fd) else return error.SkipZigTest;
    _ = c.symlink("/etc/hosts", escape); // escapes to a real file outside the jail

    // The jail root is the canonical path (/tmp is a symlink to /private/tmp on macOS).
    var rootbuf: [1024]u8 = undefined;
    const root_c = libc.realpath(jail, &rootbuf) orelse return error.SkipZigTest;
    const root = std.mem.span(root_c);

    var out: [1024]u8 = undefined;
    // Read of a file inside the jail -> accepted.
    try testing.expect(jailedPath(&out, root, inside, false) != null);
    // Read through a symlink that escapes the jail -> rejected (realpath resolves out).
    try testing.expect(jailedPath(&out, root, escape, false) == null);
    // Read of a path plainly outside the jail -> rejected.
    try testing.expect(jailedPath(&out, root, "/etc/hosts", false) == null);
    // Create a new file in the jail (parent exists) -> accepted.
    try testing.expect(jailedPath(&out, root, jail ++ "/new.txt", true) != null);
    // Create with a `..` that escapes the jail -> rejected (parent resolves outside).
    try testing.expect(jailedPath(&out, root, jail ++ "/../escape.txt", true) == null);
    // Create into a non-existent subdir -> rejected (parent realpath fails).
    try testing.expect(jailedPath(&out, root, jail ++ "/nope/x.txt", true) == null);
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
    try testing.expect(std.mem.indexOf(u8, out, "cpu_ms=") != null); // per-command CPU attribution
    try testing.expect(std.mem.indexOf(u8, out, "exit=0 cpu_ms=") != null);
    try testing.expect(std.mem.indexOf(u8, out, " echo hi\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "exit=1 cpu_ms=") != null);
    try testing.expect(std.mem.indexOf(u8, out, " false\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "exit=2 cpu_ms=") != null);
    try testing.expect(std.mem.indexOf(u8, out, " grep x f\n") != null);
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
    try testing.expect(std.mem.indexOf(u8, out, "exit=12 cpu_ms=") != null);
    try testing.expect(std.mem.indexOf(u8, out, " cmd\n") != null);
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

test "Capture.feed survives hostile agent replies (GET + PUT, split chunks)" {
    // The host-mediated transfer parses the GUEST AGENT's reply bytes (attacker
    // controlled): a "OK <len>\n" header then a raw body for GET, a status line for
    // PUT. Drive random and header-shaped replies in random chunk splits; assert no
    // safety trip and that the completed GET body slice stays in bounds.
    var prng = std.Random.DefaultPrng.init(0xCA97_07E);
    const rand = prng.random();
    var round: usize = 0;
    while (round < 30000) : (round += 1) {
        const is_get = (round & 1) == 0;
        var gbuf: [512]u8 = undefined;
        var cap = Capture{ .is_get = is_get, .buf = &gbuf };

        // Build a reply: often header-shaped (real parser path), sometimes pure random.
        var reply_buf: [900]u8 = undefined;
        var rlen: usize = 0;
        if (is_get and rand.boolean()) {
            // "OK <flen>\n" + flen body bytes; flen sometimes exceeds the buffer cap
            // (must be rejected), sometimes fits.
            const flen = rand.uintLessThan(usize, 700);
            const hdr = std.fmt.bufPrint(&reply_buf, "OK {d}\n", .{flen}) catch unreachable;
            rlen = hdr.len;
            const body = @min(flen, reply_buf.len - rlen);
            rand.bytes(reply_buf[rlen..][0..body]);
            rlen += body;
        } else {
            rlen = rand.uintLessThan(usize, reply_buf.len);
            rand.bytes(reply_buf[0..rlen]);
        }

        // Feed in random-sized chunks until done or exhausted.
        var off: usize = 0;
        while (off < rlen and !cap.done.load(.acquire)) {
            const chunk = 1 + rand.uintLessThan(usize, 17);
            const end = @min(off + chunk, rlen);
            cap.feed(reply_buf[off..end]);
            off = end;
        }

        // Invariant: a completed, non-error GET yields an in-bounds body slice.
        if (is_get and cap.done.load(.acquire) and !cap.err) {
            try testing.expect(cap.body_off <= cap.expect);
            try testing.expect(cap.expect <= gbuf.len);
            std.mem.doNotOptimizeAway(cap.buf[cap.body_off..cap.expect]);
        }
    }
}
