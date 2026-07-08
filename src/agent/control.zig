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
    data_conns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0), // data-plane conns accepted (3b)
    data_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0), // summed data-plane conn lifetimes
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
            \\data_conns={d}
            \\data_ms={d}
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
            self.data_conns.load(.acquire),
            self.data_ms.load(.acquire),
            @as(u8, 0x1e),
        }) catch return framedErr(buf, "ERR report render failed")).len;
    }

    /// One-line, machine-readable usage summary for the teardown "bill" - the same
    /// numbers as `__stats__` (compute, memory, I/O, network) but compact and emitted
    /// unconditionally at session end, so the platform always captures a final
    /// accounting even if the client never polled `__stats__`.
    pub fn summary(self: *Metering, buf: []u8) []const u8 {
        const net_tx = if (self.net) |s| s.tx_bytes.load(.monotonic) else 0;
        const net_rx = if (self.net) |s| s.rx_bytes.load(.monotonic) else 0;
        const net_blocked = if (self.net) |s| s.blocked_count.load(.monotonic) else 0;
        return std.fmt.bufPrint(buf, "uptime_ms={d} cpu_ms={d} mem_peak_mb={d} ram_mb={d} cpus={d} commands={d} bytes_in={d} bytes_out={d} net_tx={d} net_rx={d} net_blocked={d} data_conns={d} data_ms={d}", .{
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
            self.data_conns.load(.acquire),
            self.data_ms.load(.acquire),
        }) catch buf[0..0];
    }
};

/// Control-protocol version, surfaced in `__info__` (`proto_version=`). Bump on any
/// breaking change to the command set or wire format so an integrating client (swerver)
/// can check compatibility before driving the sandbox. The command list itself is
/// discoverable at runtime via `__help__` and documented in docs/control-protocol.md.
pub const PROTO_VERSION = 2;

/// Default per-command output cap (govern) when `max_output_bytes` is unset. A command's
/// stdout/stderr is bounded to this many bytes; the rest is dropped with a one-time
/// `[output capped]` notice, and the `0x1e<exit>` trailer is ALWAYS still sent (so the
/// reply stays a complete frame and the exit code always arrives). Bounded by default so a
/// runaway/hostile command cannot flood the control channel or the billed bytes_out; large
/// payloads should move over `__get__` (file transfer), not command stdout. 0 in conf =
/// explicitly unlimited. This is the nether end of the control-protocol output-bound
/// contract (see docs/control-protocol.md); the trailer guarantee lets a client drain to
/// the frame boundary regardless of its own read cap.
pub const DEFAULT_MAX_OUTPUT_BYTES: u64 = 1 << 20; // 1 MiB

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
    x402: bool = false, // settlement mode: on = billable (teardown emits an x402 settlement); off = general workload
    app_port: u32 = 0, // tenant loopback port bridged via the data plane (0 = no data plane) (3b)
    max_data_conns: u64 = 0, // cap on concurrent data-plane conns (0 = engine default)
    data_idle_ms: u64 = 0, // per-conn data-plane idle reap (0 = disabled)
    data_rate_kbps: u64 = 0, // per-VM data-plane bandwidth cap (0 = unlimited)

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
            \\x402={s}
            \\data_plane={s}
            \\app_port={d}
            \\max_data_conns={d}
            \\data_idle_ms={d}
            \\data_rate_kbps={d}
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
            onOff(self.x402),
            onOff(self.app_port > 0),
            self.app_port,
            self.max_data_conns,
            self.data_idle_ms,
            self.data_rate_kbps,
            @as(u8, 0x1e),
        }) catch return framedErr(buf, "ERR report render failed")).len;
    }
};

/// Parse the optional numeric screen id after a `__screen__ `/`__screendiff__ ` prefix.
/// 0 (no arg / unparseable) means "the current/latest command's screen".
fn screenArgId(line: []const u8, prefix: []const u8) u64 {
    if (!std.mem.startsWith(u8, line, prefix)) return 0;
    const arg = std.mem.trim(u8, line[prefix.len..], " \r\n");
    return std.fmt.parseInt(u64, arg, 10) catch 0;
}

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
    /// Settlement mode (x402). OFF by default: a general workload is fully metered and
    /// governed, but its teardown record is operational telemetry only, not a billable
    /// settlement. ON: the same record is framed as an x402 settlement (the billable
    /// signal the payment layer keys off). Metering/stats/caps are unaffected either way.
    x402: bool = false,

    /// Wire the core state in place and emit the boot lifecycle event.
    pub fn init(self: *Core, ram_mb: u64, cpus: u32, max_output: usize) void {
        self.meter = .{ .start_ms = nowMs(), .ram_mb = ram_mb, .cpus = cpus };
        self.agent.journal = &self.journal;
        self.agent.meter = &self.meter; // agent output is activity for the idle watchdog
        self.agent.max_output = max_output; // govern: per-command output cap
        self.journal.emit(.life, "boot");
    }

    /// Emit the teardown usage record: print it (the platform that spawned nether reads
    /// its stdout/stderr) and mirror it into the journal as a LIFE event. Called once when
    /// the run loop returns - for ANY reason (guest shutdown, runtime/cpu/idle budget,
    /// __shutdown__, SIGTERM) - so every session ends with a guaranteed, machine-readable
    /// record. The prefix is the x402 toggle: `x402 settlement` when settlement mode is on
    /// (the billable signal), `final usage` when off (general-workload telemetry). The
    /// metered fields are identical; only the framing differs.
    /// The teardown record's prefix: the billable `x402 settlement` when settlement mode
    /// is on, else `final usage` (general-workload telemetry). The platform keys billing
    /// off the settlement prefix, so the two must never be confused.
    pub fn recordKind(self: *const Core) []const u8 {
        return if (self.x402) "x402 settlement" else "final usage";
    }

    pub fn finalUsage(self: *Core, reason: []const u8) void {
        var buf: [256]u8 = undefined;
        const line = self.meter.summary(&buf);
        std.debug.print("[nether] {s} (reason={s}): {s}\n", .{ self.recordKind(), reason, line });
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

/// Command-reply framing (must match tools/agent.c). A reply is the command's output
/// followed by a trailer `OUT_DELIM <exit> \n`. Untrusted command stdout can contain any
/// byte, so the agent delimiter-ESCAPES the body: an OUT_DELIM or OUT_ESC in the body is
/// emitted as `OUT_ESC, (byte ^ OUT_ESC_XOR)`. A raw OUT_DELIM therefore appears on the
/// wire ONLY as the real trailer - the body cannot forge a frame boundary (R2b). The host
/// trailer scanners below just look for a raw OUT_DELIM (now unforgeable); un-escaping is
/// only needed to reconstruct the literal output for display. See docs/control-protocol.md.
pub const OUT_DELIM: u8 = 0x1e;
pub const OUT_ESC: u8 = 0x1f;
const OUT_ESC_XOR: u8 = 0x40;

/// Un-escape command-output body bytes (inverse of agent.c write_escaped). `esc` carries
/// a mid-escape (a trailing OUT_ESC) across calls so it streams over arbitrary chunking.
/// Decoded length is always <= in.len (escapes only shrink), so `out` must be >= in.len.
fn outUnescape(in: []const u8, out: []u8, esc: *bool) usize {
    var n: usize = 0;
    for (in) |b| {
        if (esc.*) {
            out[n] = b ^ OUT_ESC_XOR;
            n += 1;
            esc.* = false;
        } else if (b == OUT_ESC) {
            esc.* = true;
        } else {
            out[n] = b;
            n += 1;
        }
    }
    return n;
}

pub const AgentCtx = struct {
    conn_id: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),
    /// Control-socket mode: agent replies are written raw to this pipe for the
    /// relay thread to forward to the connected control client. -1 = REPL mode
    /// (parse and print to stdout instead).
    pipe_w: i32 = -1,
    /// A reference to the ControlCtx primary-client slot, so the device (vCPU) thread can
    /// drop a WEDGED client when the pipe fills (a non-reading primary). Set in startControl;
    /// null in REPL/pre-control modes. See pipePush - this keeps a wedged reader from ever
    /// blocking the vCPU behind a full pipe (audit finding: wedged reader stalls the guest).
    client: ?*std.atomic.Value(i32) = null,
    /// When set, agent reply bytes are diverted into this capture (file transfer)
    /// instead of relayed/printed. Set/cleared by the control thread.
    capture: std.atomic.Value(?*Capture) = std.atomic.Value(?*Capture).init(null),
    /// The render pillar: when set, each command's output is teed into its own VT screen
    /// (a bounded per-command history) so the platform can fetch a rendered snapshot via
    /// `__screen__ [id]` (default = the latest command's screen).
    renders: ?*nether.RenderMap = null,
    parsing_exit: bool = false, // mid-parse of the 0x1e<code>\n trailer
    exit_buf: [16]u8 = undefined,
    exit_len: usize = 0,
    repl_esc: bool = false, // REPL display: mid-escape carried across recv buffers
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
        // Start a fresh render screen for this command so its output does not overwrite the
        // previous one (per-command history; the next .recv bytes tee into this screen).
        if (a.renders) |rm| _ = rm.rotate();
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

    /// Push agent reply bytes into the relay pipe WITHOUT ever blocking the vCPU. The pipe is
    /// non-blocking (set in startControl); a healthy control client drains it in microseconds.
    /// On a full pipe we poll briefly for space - backpressure, so a momentarily-slow but
    /// healthy client catches up and NEVER loses output - and only if the pipe stays full do we
    /// drop the wedged client (which unblocks the relay to resume draining) and retry. So a
    /// wedged reader stalls the vCPU at most ~PIPE_WEDGE_MS, not the relay's full 5s.
    fn pipePush(a: *AgentCtx, bytes: []const u8) void {
        if (a.pipe_w < 0) return;
        var off: usize = 0;
        while (off < bytes.len) {
            const w = libc.write(a.pipe_w, bytes[off..].ptr, bytes.len - off);
            if (w > 0) {
                off += @intCast(w);
                continue;
            }
            // Full pipe (EAGAIN): brief backpressure so a healthy client catches up, no loss.
            const p1 = hostutil.pollRW(a.pipe_w, true, PIPE_WEDGE_MS);
            if (p1 >= 0 and (p1 & 2) != 0) continue; // space freed: retry
            if (p1 < 0) return; // pipe hangup
            // Still full: the reader is wedged. Drop it so the relay resumes draining, retry
            // once; if it is somehow still stuck, drop the rest rather than stall the vCPU.
            a.dropClient();
            const p2 = hostutil.pollRW(a.pipe_w, true, PIPE_WEDGE_MS);
            if (!(p2 >= 0 and (p2 & 2) != 0)) return;
        }
    }

    /// Drop the primary control client (a wedged reader): clear the slot if we still hold it
    /// and shutdown the fd so the relay's blocked write fails and it resumes draining. Uses
    /// cmpxchg so it never clobbers a fresh primary that already reclaimed the slot.
    fn dropClient(a: *AgentCtx) void {
        const slot = a.client orelse return;
        const c = slot.load(.acquire);
        if (c >= 0 and slot.cmpxchgStrong(c, -1, .acq_rel, .acquire) == null) {
            hostutil.shutdownRdwr(c);
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
                if (i > span) a.pipePush(bytes[span..i]); // flush forwarded run
                if (!a.cmd_truncated) {
                    a.cmd_truncated = true;
                    a.pipePush("\n...[output capped]\n");
                }
                span = i + 1; // skip the suppressed byte
            }
        }
        if (bytes.len > span) a.pipePush(bytes[span..bytes.len]);
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
        var dec: [4096]u8 = undefined;
        while (i < bytes.len) {
            if (a.parsing_exit) {
                if (bytes[i] == '\n') {
                    std.debug.print("[exit {s}]\n", .{a.exit_buf[0..a.exit_len]});
                    a.parsing_exit = false;
                    a.exit_len = 0;
                    a.repl_esc = false; // reset escape state at the frame boundary
                } else if (a.exit_len < a.exit_buf.len) {
                    a.exit_buf[a.exit_len] = bytes[i];
                    a.exit_len += 1;
                }
                i += 1;
            } else {
                const start = i;
                while (i < bytes.len and bytes[i] != OUT_DELIM) i += 1;
                // Un-escape the body span (in bounded chunks) so the REPL shows the literal
                // output, not the on-wire escapes. dec.len >= chunk, so it never overflows.
                var off = start;
                while (off < i) {
                    const take = @min(dec.len, i - off);
                    const m = outUnescape(bytes[off .. off + take], &dec, &a.repl_esc);
                    if (m > 0) _ = std.c.write(1, dec[0..m].ptr, m);
                    off += take;
                }
                if (i < bytes.len) { // hit the raw OUT_DELIM trailer
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

            if (a.renders) |rm| rm.feed(r.bytes); // tee output into the current command's screen
            a.auditRecv(r.bytes); // observe exit codes for the command audit log
            if (a.pipe_w >= 0) {
                if (a.max_output == 0) {
                    a.pipePush(r.bytes); // -> relay -> control client (non-blocking)
                } else a.relayCapped(r.bytes); // govern: bound a runaway command's output
            } else a.onRecv(r.bytes);
        },
        .shutdown, .reset => a.conn_id.store(-1, .release),
        else => {},
    }
}

/// The connection id an event carries, if any (for routing host-dialed conns).
fn evConn(ev: nether.vsock.Event) ?u16 {
    return switch (ev) {
        .accept => |id| id,
        .connected => |id| id,
        .recv => |r| r.conn,
        .shutdown => |id| id,
        .reset => |id| id,
    };
}

/// P0 spike for the Phase-2 data-plane bridge (docs/park-concurrency-plan.md): drives
/// ONE host-initiated vsock connection to a guest-listening port and records its
/// lifecycle, so `__vsockprobe__` can prove host->guest connect + RW + teardown on a
/// live guest before the real bridge is built. Its own lock (NOT the vsock D3 lock)
/// guards state: events fire on the vCPU/device thread, the poll runs on the control
/// thread. This is the seed of the data-plane bridge's per-conn context.
pub const VsockProbe = struct {
    lock: Lock = .{},
    conn: ?u16 = null,
    state: State = .idle,
    echo: [128]u8 = undefined,
    echo_len: usize = 0,

    pub const State = enum { idle, connecting, established, closed, reset };

    pub fn start(self: *VsockProbe, id: u16) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.conn = id;
        self.state = .connecting;
        self.echo_len = 0;
    }

    fn owns(self: *VsockProbe, id: u16) bool {
        self.lock.lock();
        defer self.lock.unlock();
        return self.conn != null and self.conn.? == id;
    }

    /// Fires on the device thread (inside the vsock D3 lock) for our dialed conn.
    fn event(self: *VsockProbe, ev: nether.vsock.Event) void {
        self.lock.lock();
        defer self.lock.unlock();
        switch (ev) {
            .connected => self.state = .established,
            .recv => |r| {
                const n = @min(self.echo.len - self.echo_len, r.bytes.len);
                @memcpy(self.echo[self.echo_len..][0..n], r.bytes[0..n]);
                self.echo_len += n;
            },
            .shutdown => self.state = .closed,
            .reset => self.state = .reset,
            else => {},
        }
    }

    /// Copy the echo bytes into `buf` and return the current state + copied length.
    pub fn read(self: *VsockProbe, buf: []u8) struct { state: State, len: usize } {
        self.lock.lock();
        defer self.lock.unlock();
        const n = @min(buf.len, self.echo_len);
        @memcpy(buf[0..n], self.echo[0..n]);
        return .{ .state = self.state, .len = n };
    }

    pub fn clear(self: *VsockProbe) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.conn = null;
        self.state = .idle;
        self.echo_len = 0;
    }
};

/// vsock event router: a host-dialed data/probe conn's events go to the data plane
/// (the VsockProbe now; the Phase-2 bridge later); everything else - notably the
/// guest-initiated agent conn - goes to the agent. Without this, a dialed conn's
/// reset/shutdown would clobber the agent's conn-id tracking (agentEvent clears it on
/// ANY reset). Seed of the data-plane bridge (docs/park-concurrency-plan.md).
pub const VsockRouter = struct {
    agent: *AgentCtx,
    probe: ?*VsockProbe = null,
    bridge: ?*DataBridge = null,

    pub fn dispatch(ctx: *anyopaque, ev: nether.vsock.Event) void {
        const self: *VsockRouter = @ptrCast(@alignCast(ctx));
        if (self.bridge) |b| if (b.tryEvent(ev)) return; // data-plane conn?
        if (self.probe) |p| {
            if (evConn(ev)) |id| {
                if (p.owns(id)) return p.event(ev);
            }
        }
        agentEvent(self.agent, ev);
    }
};

/// The in-guest forwarder's vsock listen port (the agent owns 5000). The host bridge dials
/// this; the forwarder relays to the tenant's loopback server. Must match tools/forwarder.c.
const FWD_VSOCK_PORT: u32 = 5001;

/// Host-side data-plane bridge (Phase 2 step 2b, docs/park-concurrency-plan.md 3b): a
/// Unix-domain listener swerver connects to. Each accepted connection is spliced to a
/// fresh host->guest vsock stream to the in-guest forwarder, which relays to the tenant's
/// loopback server - so a tenant's ordinary TCP server is reachable as a concurrent
/// upstream. Many conns run at once.
///
/// The two directions run on different threads: unix->vsock in a per-conn PUMP thread
/// (blocking read -> hostSendAll), vsock->unix from the VsockRouter event (device thread:
/// .recv -> write the unix fd). The pump thread OWNS closing both fds; the device thread
/// only shutdown()s the unix fd to wake a blocked pump. Lock order is strict and
/// inversion-free: the device thread holds the vsock D3 lock THEN this lock (in tryEvent);
/// pump/listener threads take this lock and the D3 lock (hostConnect/hostSend/hostClose)
/// but NEVER both at once.
pub const DataBridge = struct {
    vsdev: *nether.VsockDev,
    path: [*:0]const u8,
    meter: ?*Metering = null,
    alloc: std.mem.Allocator = undefined, // for per-conn delivery buffers
    lock: Lock = .{},
    conns: [MAX_BRIDGE]Entry = [_]Entry{.{}} ** MAX_BRIDGE,
    next_port: u32 = 40000,
    max_conns: usize = MAX_BRIDGE, // govern cap on concurrent data-plane conns (<= MAX_BRIDGE)
    idle_ms: u64 = 0, // per-conn idle timeout (data_idle_ms; 0 = disabled): reap slow/leaked conns
    window: u32 = WINDOW, // per-conn vsock RX window == delivery-buffer capacity
    // Per-VM data-plane bandwidth cap (govern): a token bucket over the guest->host DELIVERY
    // to the consumer, shared across all data conns. Because delivery credits the guest on
    // delivery, pacing delivery paces the guest's send (it stalls at the 256 KiB window), so
    // a flooding tenant is capped without dropping bytes. 0 = unlimited. rate_bps bytes/sec.
    rate_bps: u64 = 0,
    pace_lock: Lock = .{},
    tokens: i64 = 0, // available delivery budget (bytes); refilled at rate_bps
    pace_ms: i64 = 0, // last token refill time

    pub const MAX_BRIDGE = 48; // < vsock MAX_CONNS (64): headroom for the agent + probe conns
    pub const WINDOW: u32 = 256 * 1024; // guest in-flight bound == per-conn delivery buffer size
    const PACE_TICK_MS = 20; // pump pacing granularity under a rate cap (smooth + no busy-spin)
    const State = enum { connecting, established, dead };
    const Entry = struct {
        active: bool = false,
        state: State = .connecting,
        vsock_id: u16 = 0,
        unix_fd: c_int = -1,
        start_ms: i64 = 0, // for the data_ms lifetime meter
        last_ms: i64 = 0, // last activity either direction, for the idle reaper
        // Delivery ring buffer (guest->consumer). onRw (device thread) buffers here; the
        // device thread and the pump drain it to the unix socket with NON-BLOCKING sends -
        // so the vCPU/device thread NEVER blocks (the Medium finding) - and credit the guest
        // only for what actually drained. Capacity == the conn's window, so it never overflows.
        buf: []u8 = &.{},
        bh: usize = 0, // ring read head
        bc: usize = 0, // bytes currently buffered
    };

    /// Append to a conn's delivery ring (caller holds the lock). false = would overflow,
    /// which cannot happen while the guest respects our window == capacity; the caller drops.
    fn bufAppend(e: *Entry, bytes: []const u8) bool {
        if (e.bc + bytes.len > e.buf.len) return false;
        var off: usize = 0;
        while (off < bytes.len) {
            const wpos = (e.bh + e.bc) % e.buf.len;
            const run = @min(bytes.len - off, e.buf.len - wpos);
            @memcpy(e.buf[wpos..][0..run], bytes[off..][0..run]);
            e.bc += run;
            off += run;
        }
        return true;
    }

    /// Take up to `want` bytes of delivery budget from the per-VM token bucket, refilling by
    /// elapsed time at rate_bps first. Returns the granted amount (== want when unlimited).
    /// The bucket is shared across all data conns, so both the device thread (tryEvent) and
    /// the pump threads call this - hence pace_lock.
    fn takeTokens(self: *DataBridge, want: usize) usize {
        if (self.rate_bps == 0) return want; // unlimited: no pacing
        self.pace_lock.lock();
        defer self.pace_lock.unlock();
        const now = nowMs();
        if (now > self.pace_ms) {
            const add = @divFloor((now - self.pace_ms) * @as(i64, @intCast(self.rate_bps)), 1000);
            self.tokens += add;
            self.pace_ms = now;
            const burst: i64 = @intCast(self.rate_bps / 5); // cap accrual at ~200ms of rate
            if (self.tokens > burst) self.tokens = burst;
        }
        if (self.tokens <= 0) return 0;
        const grant = @min(want, @as(usize, @intCast(self.tokens)));
        self.tokens -= @intCast(grant);
        return grant;
    }

    /// Return budget taken but not spent (e.g. the unix socket filled before we sent it all).
    fn returnTokens(self: *DataBridge, n: usize) void {
        if (self.rate_bps == 0 or n == 0) return;
        self.pace_lock.lock();
        defer self.pace_lock.unlock();
        self.tokens += @intCast(n);
    }

    /// Drain a conn's ring to its unix socket with NON-BLOCKING sends (caller holds the
    /// lock). Returns the bytes delivered, which the caller credits back to the guest. Under
    /// a rate cap the drain is bounded by the per-VM token bucket: the excess stays buffered
    /// (the pump flushes it as tokens refill), and since we credit only what we deliver, the
    /// guest stalls at its 256 KiB window - so a flooding tenant is paced, not dropped.
    fn bufDrain(self: *DataBridge, e: *Entry, paced: bool) usize {
        var delivered: usize = 0;
        while (e.bc > 0 and e.unix_fd >= 0) {
            const run = @min(e.bc, e.buf.len - e.bh); // contiguous span from the head
            // Teardown flush passes paced=false: the guest is already gone (no flood to pace,
            // no crediting), so we must deliver the tail unthrottled and not risk truncating it.
            const grant = if (paced) self.takeTokens(run) else run;
            if (grant == 0) break; // rate cap reached: leave the rest buffered (paced)
            const n = hostutil.trySend(e.unix_fd, e.buf[e.bh..][0..grant]);
            if (paced and n < grant) self.returnTokens(grant - n); // unsent budget back to the bucket
            if (n == 0) break; // unix full (or error); the pump retries on POLLOUT
            e.bh = (e.bh + n) % e.buf.len;
            e.bc -= n;
            delivered += n;
            if (n < run) break; // partial: socket is full (or token-capped)
        }
        return delivered;
    }

    pub fn start(self: *DataBridge) void {
        if (std.Thread.spawn(.{}, listenerLoop, .{self})) |t| t.detach() else |_| {
            std.debug.print("[bridge] failed to start data-plane listener\n", .{});
        }
        if (std.Thread.spawn(.{}, reaperLoop, .{self})) |t| t.detach() else |_| {}
    }

    /// Reap conns idle in BOTH directions for longer than `idle_ms` - so a slow or wedged
    /// guest server (accepts a request, then goes silent) cannot tie up a bridge slot
    /// indefinitely. Marks the conn dead and shutdown()s its unix fd; the pump thread's
    /// blocked read then returns and tears it down (single-owner close). No-op if disabled.
    fn reaperLoop(self: *DataBridge) void {
        while (true) {
            _ = usleep(500_000); // 2 Hz
            if (self.idle_ms == 0) continue;
            const cutoff: i64 = @intCast(self.idle_ms);
            const now = nowMs();
            self.lock.lock();
            for (&self.conns) |*e| {
                if (e.active and e.state != .dead and (now - e.last_ms) > cutoff) {
                    e.state = .dead;
                    if (e.unix_fd >= 0) hostutil.shutdownRdwr(e.unix_fd);
                }
            }
            self.lock.unlock();
        }
    }

    fn findId(self: *DataBridge, id: u16) ?usize {
        for (&self.conns, 0..) |*e, i| if (e.active and e.vsock_id == id) return i;
        return null;
    }

    /// Router hook (device thread, inside the vsock D3 lock): handle an event for a
    /// bridge-owned conn. Returns true iff this conn belongs to the bridge.
    pub fn tryEvent(self: *DataBridge, ev: nether.vsock.Event) bool {
        const id = evConn(ev) orelse return false;
        self.lock.lock();
        defer self.lock.unlock();
        const i = self.findId(id) orelse return false;
        const e = &self.conns[i];
        switch (ev) {
            .connected => e.state = .established,
            .recv => |r| {
                // Device thread, INSIDE the vsock D3 lock, so it must NEVER block (the Medium
                // finding: a blocking write here freezes the whole guest vsock on a wedged
                // consumer). Buffer the payload (always fits: window == capacity, so in-flight
                // <= capacity), drain to the unix socket NON-BLOCKING, and credit the guest only
                // for what delivered. A slow consumer stops getting credit -> the guest server
                // backpressures (its write blocks) -> no flood, no drop, no stall.
                if (!bufAppend(e, r.bytes)) {
                    e.state = .dead; // window violated (should be impossible): drop
                    if (e.unix_fd >= 0) hostutil.shutdownRdwr(e.unix_fd);
                } else {
                    const delivered = self.bufDrain(e, true);
                    if (delivered > 0) {
                        self.vsdev.engine.creditRecv(e.vsock_id, @intCast(delivered)); // inline, under D3
                        if (self.meter) |m| _ = m.bytes_out.fetchAdd(delivered, .release);
                    }
                    e.last_ms = nowMs();
                    if (self.meter) |m| m.touch(); // data-plane traffic = sandbox activity
                }
            },
            .shutdown => {
                // Graceful guest FIN: the delivery ring may still hold a tail (up to a full
                // window under a rate cap). Half-close only our READ side so the blocked pump
                // wakes on read-EOF and runs teardown, whose flush delivers that tail over the
                // still-open WRITE side before closing - lossless. (Full shutdown here would
                // drop the tail, which pacing exposed by keeping the ring full at close.)
                e.state = .dead;
                if (e.unix_fd >= 0) hostutil.shutdownRd(e.unix_fd);
            },
            .reset => {
                // Abort: drop whatever is buffered and tear down immediately.
                e.state = .dead;
                if (e.unix_fd >= 0) hostutil.shutdownRdwr(e.unix_fd); // wake the blocked pump
            },
            else => {},
        }
        return true;
    }

    fn register(self: *DataBridge, id: u16, unix_fd: c_int) ?usize {
        self.lock.lock();
        defer self.lock.unlock();
        var active: usize = 0;
        var free: ?usize = null;
        for (&self.conns, 0..) |*e, i| {
            if (e.active) active += 1 else if (free == null) free = i;
        }
        if (active >= self.max_conns) return null; // govern cap reached
        const slot = free orelse return null; // pool full
        const buf = self.alloc.alloc(u8, self.window) catch return null; // delivery buffer
        const now = nowMs();
        self.conns[slot] = .{ .active = true, .state = .connecting, .vsock_id = id, .unix_fd = unix_fd, .start_ms = now, .last_ms = now, .buf = buf };
        if (self.meter) |m| _ = m.data_conns.fetchAdd(1, .release);
        return slot;
    }

    /// Close both fds + free the slot. The pump thread is the single owner of this.
    fn teardown(self: *DataBridge, slot: usize) void {
        self.lock.lock();
        var e = self.conns[slot];
        self.conns[slot] = .{}; // clear slot (inactive + buf detached) so a late event skips it
        self.lock.unlock();
        if (!e.active) return;
        // Reset the guest conn FIRST so no more .recv fires for this (freed) slot; the buffer
        // already holds whatever was received.
        self.vsdev.hostClose(e.vsock_id);
        // Graceful flush: deliver the remaining buffered bytes to the consumer before closing
        // (a normal guest close must not lose the response tail). Bounded (~5s) so a wedged
        // consumer can't hang teardown; the guest is already gone, so no crediting is needed.
        var budget: u32 = 0;
        while (e.bc > 0 and e.unix_fd >= 0 and budget < 500) : (budget += 1) {
            if (self.bufDrain(&e, false) > 0) continue;
            if (hostutil.pollRW(e.unix_fd, true, 10) < 0) break; // consumer gone / error
        }
        if (self.meter) |m| _ = m.data_ms.fetchAdd(@intCast(@max(0, nowMs() - e.start_ms)), .release);
        if (e.unix_fd >= 0) _ = libc.close(e.unix_fd);
        if (e.buf.len > 0) self.alloc.free(e.buf);
    }

    fn listenerLoop(self: *DataBridge) void {
        const fd = libc.socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return;
        _ = libc.unlink(self.path);
        var addr = SockaddrUn{};
        const p = std.mem.span(self.path);
        if (p.len + 1 > addr.path.len) {
            std.debug.print("[bridge] data_socket path too long ({d})\n", .{p.len});
            return;
        }
        @memcpy(addr.path[0..p.len], p);
        const addr_len: u32 = @intCast(@offsetOf(SockaddrUn, "path") + p.len + 1);
        if (@hasField(SockaddrUn, "len")) addr.len = @intCast(addr_len);
        if (libc.bind(fd, &addr, addr_len) < 0 or libc.listen(fd, 16) < 0) {
            std.debug.print("[bridge] bind/listen failed on {s}\n", .{self.path});
            return;
        }
        if (libc.fchmod(fd, 0o600) != 0) std.debug.print("[bridge] warning: fchmod 0600 failed\n", .{});
        const owner_uid = libc.getuid();
        std.debug.print("[bridge] data plane on {s} -> guest vsock:{d}\n", .{ self.path, FWD_VSOCK_PORT });
        while (true) {
            const c = libc.accept(fd, null, null);
            if (c < 0) continue;
            // Owner-uid gate, like the control socket (same trust: it reaches into the guest).
            const peer = hostutil.peerUid(c);
            if (peer == null or peer.? != owner_uid) {
                _ = libc.close(c);
                continue;
            }
            // Non-blocking so the device-thread delivery (tryEvent) NEVER blocks the vCPU on a
            // wedged consumer; a large send buffer so brief lag doesn't fail a send. The pump
            // reads/drains this fd via pollRW.
            hostutil.setNonblock(c);
            hostutil.setSendBuf(c, 256 * 1024);
            // Dial the in-guest forwarder with a BOUNDED window (== the delivery-buffer size),
            // deferred-credit, so a slow consumer backpressures the guest. Register before the pump.
            self.next_port +%= 1;
            const id = self.vsdev.hostConnectWindow(self.next_port, FWD_VSOCK_PORT, self.window) orelse {
                _ = libc.close(c); // vsock conn table full
                continue;
            };
            const slot = self.register(id, c) orelse {
                self.vsdev.hostClose(id);
                _ = libc.close(c); // bridge pool full
                continue;
            };
            if (std.Thread.spawn(.{}, pumpLoop, .{ self, slot })) |t| t.detach() else |_| self.teardown(slot);
        }
    }

    fn pumpLoop(self: *DataBridge, slot: usize) void {
        // Wait (bounded) for the host->guest connect to establish (the guest forwarder accepts).
        var waited: u32 = 0;
        while (waited < 3000) : (waited += 10) {
            self.lock.lock();
            const st = self.conns[slot].state;
            self.lock.unlock();
            if (st != .connecting) break;
            _ = usleep(10_000);
        }
        self.lock.lock();
        const e = self.conns[slot];
        self.lock.unlock();
        if (e.state != .established) return self.teardown(slot);
        // The unix fd is non-blocking. Poll it for READ (consumer->guest) and, whenever the
        // delivery buffer has bytes, for WRITE (drain buffer->consumer). Draining credits the
        // guest for what delivered, reopening its window (backpressure). A teardown/reset
        // shutdown()s the fd -> pollRW reports a hangup (-1) -> we break. Lock order is safe:
        // we take the bridge lock and the D3 lock (hostSendAll/hostCredit) but NEVER both at once.
        var buf: [16384]u8 = undefined;
        while (true) {
            self.lock.lock();
            const has_buf = self.conns[slot].active and self.conns[slot].bc > 0;
            self.lock.unlock();
            const pr = hostutil.pollRW(e.unix_fd, has_buf, 1000);
            if (pr < 0) break; // hangup / error
            if (pr == 0) continue; // timeout
            if (pr & 1 != 0) { // consumer -> guest
                const n = libc.read(e.unix_fd, &buf, buf.len);
                if (n == 0) break; // EOF
                if (n > 0) {
                    if (!hostSendAll(self.vsdev, e.vsock_id, buf[0..@intCast(n)])) break;
                    self.lock.lock();
                    if (self.conns[slot].active) self.conns[slot].last_ms = nowMs();
                    self.lock.unlock();
                    if (self.meter) |m| {
                        _ = m.bytes_in.fetchAdd(@intCast(n), .release);
                        m.touch();
                    }
                }
            }
            if (pr & 2 != 0) { // socket writable -> drain the delivery buffer
                self.lock.lock();
                const delivered = if (self.conns[slot].active) self.bufDrain(&self.conns[slot], true) else 0;
                if (delivered > 0 and self.conns[slot].active) self.conns[slot].last_ms = nowMs();
                const backlog = self.conns[slot].active and self.conns[slot].bc > 0;
                self.lock.unlock();
                if (delivered > 0) {
                    self.vsdev.hostCredit(e.vsock_id, @intCast(delivered)); // D3, no bridge lock held
                    if (self.meter) |m| _ = m.bytes_out.fetchAdd(delivered, .release);
                }
                // Under a rate cap the socket stays writable while the token bucket is empty, so
                // a re-poll would return POLLOUT instantly and busy-spin. Sleep one pacing tick
                // to let tokens refill; this is also what smooths delivery to ~rate_bps.
                if (self.rate_bps != 0 and backlog) _ = usleep(PACE_TICK_MS * 1000);
            }
        }
        self.teardown(slot);
    }
};

/// Fuzz driver for the data-plane bridge's event + lifecycle logic (the new attacker
/// surface in step 2b: a hostile/misbehaving guest server drives the vsock events that
/// reach `tryEvent`). Drives a hostile sequence of register / connected / recv / reset /
/// teardown against a DataBridge and asserts the invariants hold: the conn table stays
/// bounded, findId never OOBs, events for unknown/stale/duplicate ids are safe, and
/// teardown never double-closes. Single-threaded: it exercises logic/memory-safety, not
/// thread interleaving (that is argued by the strict lock order + the live concurrent
/// test). Used by "fuzz: data-plane bridge" (fuzz.zig) and the loop test below.
/// unix_fd points at /dev/null so writes always succeed and never block.
pub fn fuzzBridge(bytes: []const u8) void {
    var eng = nether.Vsock{ .guest_cid = 3 };
    var dev = nether.VsockDev{ .engine = &eng }; // unattached: hostClose = engine.close, flush no-op
    var br = DataBridge{ .vsdev = &dev, .path = "", .alloc = std.testing.allocator, .window = 4096 };
    defer { // close any fds left in the table so the driver doesn't leak across inputs
        var s: usize = 0;
        while (s < DataBridge.MAX_BRIDGE) : (s += 1) br.teardown(s);
    }
    var i: usize = 0;
    while (i + 2 <= bytes.len) : (i += 2) {
        const arg = bytes[i + 1];
        const id: u16 = @intCast(arg % 60); // a small id space (< MAX_CONNS) so hits are common
        switch (@as(u2, @truncate(bytes[i]))) {
            0 => { // register a conn with a fresh /dev/null fd (slot may be full)
                const fd = libc.open("/dev/null", 2, @as(c_int, 0)); // O_RDWR
                if (fd >= 0 and br.register(id, fd) == null) _ = libc.close(fd);
            },
            1 => _ = br.tryEvent(.{ .connected = id }),
            2 => {
                var payload = [_]u8{ arg, arg ^ 0xff, 0x1e, 0x1f };
                _ = br.tryEvent(.{ .recv = .{ .conn = id, .bytes = payload[0..] } });
            },
            3 => {
                if (arg & 1 == 0) {
                    _ = br.tryEvent(.{ .reset = id });
                } else {
                    br.teardown(arg % DataBridge.MAX_BRIDGE);
                }
            },
        }
        var active: usize = 0;
        for (br.conns) |e| {
            if (e.active) active += 1;
        }
        std.debug.assert(active <= DataBridge.MAX_BRIDGE);
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
    snapshot: ?platform.Snapshotter = null, // on-demand base capture, for __snapshot__
    gpu: ?*nether.VirtioGpu = null, // for the __frame__ render command
    journal: ?*nether.Journal = null, // unified event timeline, for __events__
    probe: ?*VsockProbe = null, // P0 data-plane spike, for __vsockprobe__ (HVF)
    info: SandboxInfo = .{}, // static capabilities/limits, for __info__
    // How long a driving command waits for the in-guest agent to connect before failing
    // with an ERR (rather than blocking this control thread forever). Generous enough for
    // a microVM boot; a guest that never connects (broken image) then fails cleanly.
    agent_wait_ms: u32 = 30_000,
    // The primary control client (fd) - the one connection that drives the sandbox
    // and receives the agent relay stream. Additional connections are read-only
    // observers (host-intercepted queries only); -1 = no primary.
    client: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),
    // Bumped every time a client claims the primary slot. The relay reads it to detect a
    // primary handoff: if a NEW primary claims while a command's output is still streaming,
    // the relay skips the departed primary's tail (to the next 0x1e trailer boundary) so the
    // leftover does not desync the new primary's session (audit finding: relay tail leak).
    client_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    active_clients: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    // File-transfer jail, pinned once at listener start (not per call) so the jail
    // can't move if the process cwd ever changes. Empty until set => fail closed.
    xfer_root_buf: [PATH_MAX]u8 = undefined,
    xfer_root_len: usize = 0,

    fn xferRoot(self: *const ControlCtx) []const u8 {
        return self.xfer_root_buf[0..self.xfer_root_len];
    }
};

/// Max bytes a single `__put__`/`__get__` moves. Bounds host memory and frames the
/// guest-side payload; large enough for typical task payloads/artifacts.
const MAX_XFER: usize = 16 * 1024 * 1024;

/// realpath destination / jailed-path buffer size. Must be >= the platform PATH_MAX, which
/// is 1024 on macOS but 4096 on Linux - realpath writes the full CANONICAL path here (which
/// can exceed a short input), so a 1024 buffer overflows the stack on the Linux/KVM build.
const PATH_MAX: usize = 4096;

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
        if (spins > 100_000) return false; // ~10s ceiling: bounds a malformed/stalling guest's
        // hold on the control thread. A real MAX_XFER (16 MiB) transfer over local vsock is
        // sub-second, so 10s is very generous while cutting the DoS window (audit finding).
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
fn jailedPath(out: *[PATH_MAX]u8, root: []const u8, req: []const u8, creating: bool) ?[*:0]const u8 {
    if (root.len == 0) return null;
    if (req.len == 0 or req.len + 1 > out.len) return null;

    var rb: [PATH_MAX]u8 = undefined;
    if (!creating) {
        var tb: [PATH_MAX]u8 = undefined;
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
    var tb: [PATH_MAX]u8 = undefined;
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
    var pb: [PATH_MAX]u8 = undefined;
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

    var pb: [PATH_MAX]u8 = undefined;
    const hp = jailedPath(&pb, ctx.xferRoot(), hostpath, true) orelse return reply(c, "ERR host path outside transfer dir\n");
    // O_NOFOLLOW: jailedPath confirmed the path is inside the jail, but it only resolved
    // the parent dir - refuse a pre-existing symlink at the basename that would redirect
    // the write outside the jail (a defense-in-depth escape on the create-write path).
    const fd = hostutil.createTruncNoFollow(hp);
    if (fd < 0) return reply(c, "ERR cannot write host file\n");
    if (!writeAll(fd, body)) {
        // Don't leave a truncated/partial file masquerading as a real one: remove it. (The
        // open already truncated any prior file, so failure means no valid file - fail clean.)
        _ = libc.close(fd);
        _ = libc.unlink(hp);
        return reply(c, "ERR write failed\n");
    }
    _ = libc.close(fd);
    var ok: [128]u8 = undefined;
    reply(c, std.fmt.bufPrint(&ok, "OK got {d} bytes -> {s}\n", .{ body.len, hostpath }) catch "OK\n");
}

/// Write a minimal FRAMED reply (`<msg>0x1e<exit>\n`) into buf and return its length. Used
/// as the fallback when a framed report's bufPrint fails, so the reply is NEVER an empty or
/// bodyless slice with no trailer - which would hang a framed consumer waiting on the 0x1e.
/// exit -1 marks a control-plane error (audit: report `catch return 0` dropped the trailer).
fn framedErr(buf: []u8, msg: []const u8) usize {
    const r = std.fmt.bufPrint(buf, "{s}\x1e-1\n", .{msg}) catch {
        const min = "ERR\x1e-1\n";
        const n = @min(min.len, buf.len);
        @memcpy(buf[0..n], min[0..n]);
        return n;
    };
    return r.len;
}

/// Send a control-plane reply. v2 (proto_version 2): every `OK`/`ERR` reply is FRAMED with
/// the `0x1e<exit>\n` trailer - just like reports and shell commands - so a consumer reads
/// any command/ack reply with one loop and no timing heuristic (the v1 bare/framed ambiguity
/// is gone). Exit code: `0` for an `OK` ack, `-1` for a control-plane `ERR`. A guest command
/// exit is always `0..255`, so the negative code never collides - a consumer sign-tests the
/// exit to tell "the command ran and exited N" from "nether rejected the command". The body
/// is host-generated ASCII with no raw `0x1e` (the command-intake guard in controlCommand
/// rejects `0x1e`/`0x1f`), so it needs no escaping. See docs/control-protocol.md.
fn reply(c: c_int, msg: []const u8) void {
    _ = writeAll(c, msg);
    const exit: i32 = if (std.mem.startsWith(u8, msg, "OK")) 0 else -1;
    var tb: [16]u8 = undefined;
    const t = std.fmt.bufPrint(&tb, "\x1e{d}\n", .{exit}) catch return;
    _ = writeAll(c, t);
}

/// Send one command line to the guest agent (waiting for it to connect), counting
/// it for metering. `__stats__` and `__shutdown__` are intercepted here and
/// answered by the host without touching the guest.
fn controlCommand(ctx: *ControlCtx, c: c_int, line: []const u8, is_primary: bool) void {
    ctx.meter.touch(); // any client command counts as activity (resets the idle timer)
    // v2 frames every reply with a raw 0x1e trailer, so an argument echoed into a reply body
    // (e.g. a __put__/__get__ path) must not carry a 0x1e/0x1f - it could forge the frame.
    // A well-formed client never sends one (its own validateCommand rejects them); reject
    // fail-closed so every framed reply body is guaranteed delimiter-free.
    if (std.mem.indexOfScalar(u8, line, 0x1e) != null or std.mem.indexOfScalar(u8, line, 0x1f) != null)
        return reply(c, "ERR control byte in command\n");
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
            "__screen__ [id]  a command's terminal snapshot (default: the latest command)\n" ++
            "__screendiff__ [id] a command's changed rows since last call (primary-only)\n" ++
            "__frame__        framebuffer as a binary PPM\n" ++
            "__framediff__    framebuffer changed tiles since last call (primary-only)\n" ++
            "__help__         this list\n" ++
            "# primary client only (drive the sandbox):\n" ++
            "__shutdown__     clean teardown\n" ++
            "__snapshot__ [p] capture a fork-source base snapshot (default nether.snap; HVF)\n" ++
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
    // Render: snapshot a command's terminal (scrollback + live), host-intercepted like
    // __stats__. `__screen__` = the latest command's screen; `__screen__ <id>` = a specific
    // one from the retained history (see __cmdlog__-style per-command ids the render reports).
    if (std.mem.eql(u8, line, "__screen__\n") or std.mem.eql(u8, line, "__screen__") or std.mem.startsWith(u8, line, "__screen__ ")) {
        if (ctx.agent.renders) |rm| {
            const id = screenArgId(line, "__screen__ ");
            var buf: [64 * 1024]u8 = undefined;
            const n = rm.snapshot(id, &buf);
            if (n == 0 and id != 0) return reply(c, "ERR no such screen id (recycled or never existed)\n");
            _ = writeAll(c, buf[0..n]);
            _ = ctx.meter.bytes_out.fetchAdd(n, .release);
        } else reply(c, "ERR render not enabled\n");
        return;
    }
    // Render streaming: only the live rows of a command's screen that changed since the last
    // __screendiff__ (the first call emits the whole screen). `__screendiff__ [id]`.
    if (std.mem.eql(u8, line, "__screendiff__\n") or std.mem.eql(u8, line, "__screendiff__") or std.mem.startsWith(u8, line, "__screendiff__ ")) {
        if (!is_primary) return reply(c, "ERR __screendiff__ is primary-only (per-client diff state)\n");
        if (ctx.agent.renders) |rm| {
            const id = screenArgId(line, "__screendiff__ ");
            var buf: [64 * 1024]u8 = undefined;
            const n = rm.diff(id, &buf);
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
    // Lifecycle: on-demand base-snapshot capture (the platform pre-bakes a fork source
    // by driving a sandbox to a ready state, then issuing this). Host-intercepted: it
    // quiesces the guest, writes the snapshot, and resumes - the sandbox keeps running.
    // The path is confined to the transfer jail (same as __put__/__get__); default
    // `nether.snap`. Reply blocks until the capture completes (it is bounded - a quiesce
    // plus a RAM write), so the platform knows the base is on disk before it forks it.
    if (std.mem.eql(u8, line, "__snapshot__\n") or std.mem.eql(u8, line, "__snapshot__") or std.mem.startsWith(u8, line, "__snapshot__ ")) {
        const snapr = ctx.snapshot orelse return reply(c, "ERR snapshot not supported on this backend\n");
        const arg = if (std.mem.startsWith(u8, line, "__snapshot__ ")) std.mem.trim(u8, line["__snapshot__ ".len..], " \r\n") else "";
        const req = if (arg.len == 0) "nether.snap" else arg;
        var pbuf: [PATH_MAX]u8 = undefined;
        const jailed = jailedPath(&pbuf, ctx.xferRoot(), req, true) orelse return reply(c, "ERR snapshot path outside the transfer jail\n");
        if (ctx.journal) |j| j.emit(.life, "snapshot requested");
        const ok = snapr.call(jailed);
        if (ok) {
            if (ctx.journal) |j| j.emit(.life, "snapshot written");
            reply(c, "OK snapshot written\n");
        } else reply(c, "ERR snapshot capture failed\n");
        _ = ctx.meter.commands.fetchAdd(1, .release);
        return;
    }
    // Diagnostic (P0 spike, docs/park-concurrency-plan.md): prove host->guest vsock
    // connect on a LIVE guest, the go/no-go for the data-plane bridge. Dials
    // <guest_port> (a guest process must be listening on that vsock port), sends a
    // probe, reports the echo, and tears down. Events for this dialed conn are routed to
    // ctx.probe (not the agent) by VsockRouter, so the agent conn is unaffected.
    if (std.mem.startsWith(u8, line, "__vsockprobe__ ") or std.mem.eql(u8, line, "__vsockprobe__\n") or std.mem.eql(u8, line, "__vsockprobe__")) {
        const probe = ctx.probe orelse return reply(c, "ERR vsock probe not wired on this backend\n");
        const arg = if (std.mem.startsWith(u8, line, "__vsockprobe__ ")) std.mem.trim(u8, line["__vsockprobe__ ".len..], " \r\n") else "";
        const port = std.fmt.parseInt(u32, arg, 10) catch return reply(c, "ERR __vsockprobe__ <guest_port>\n");
        const id = ctx.vsdev.hostConnect(55000, port) orelse return reply(c, "ERR host connect: conn table full\n");
        probe.start(id);
        var buf: [128]u8 = undefined;
        // Wait (bounded) for the handshake: guest accept -> OP_RESPONSE -> established.
        var waited: u32 = 0;
        var snap = probe.read(&buf);
        while (snap.state == .connecting and waited < 3000) : (waited += 10) {
            _ = usleep(10_000);
            snap = probe.read(&buf);
        }
        if (snap.state != .established) {
            ctx.vsdev.hostClose(id);
            probe.clear();
            var eb: [96]u8 = undefined;
            return reply(c, std.fmt.bufPrint(&eb, "ERR host->guest connect not established (state={s})\n", .{@tagName(snap.state)}) catch "ERR host connect failed\n");
        }
        // Established: send a probe payload and wait for the guest to echo it back.
        _ = ctx.vsdev.hostSend(id, "PING\n");
        waited = 0;
        snap = probe.read(&buf);
        while (snap.len == 0 and snap.state == .established and waited < 1000) : (waited += 10) {
            _ = usleep(10_000);
            snap = probe.read(&buf);
        }
        ctx.vsdev.hostClose(id);
        // The echoed bytes are UNTRUSTED (a guest process controls them), so HEX-encode them:
        // interpolated raw they could carry a 0x1e and forge the reply frame. reply() then
        // frames the line (0x1e0\n) like every other ack. (audit: __vsockprobe__ frame hole -
        // it was the one reply path that emitted guest bytes unframed and unescaped.)
        var ob: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&ob, "OK host->guest vsock: established; echo={d}B: {x}\n", .{ snap.len, buf[0..snap.len] }) catch "OK host->guest vsock established\n";
        reply(c, msg);
        probe.clear();
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
    // Wait (bounded) for the in-guest agent to connect over vsock. The control socket
    // accepts before the guest finishes booting, so an early command must wait - but only
    // up to agent_wait_ms, so a never-connecting guest fails with an ERR instead of
    // blocking this thread (and its primary slot) forever. The bare ERR line is the
    // fast-fail signal documented for driving clients (control-protocol.md).
    var id = ctx.agent.conn_id.load(.acquire);
    var waited_ms: u32 = 0;
    while (id < 0) {
        if (waited_ms >= ctx.agent_wait_ms) {
            return reply(c, "ERR agent not connected (guest not ready)\n");
        }
        _ = usleep(50_000);
        waited_ms += 50;
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
    probe: ?*VsockProbe = null, // P0 data-plane spike, for __vsockprobe__ (HVF)
    gpu: ?*nether.VirtioGpu = null,
    stop: platform.Stop, // backend-agnostic guest stop for __shutdown__
    snapshot: ?platform.Snapshotter = null, // on-demand base capture for __snapshot__ (HVF)
    info: SandboxInfo,
    path: [*:0]const u8,
    allocator: std.mem.Allocator,
};

/// Open the control socket and start the listener + relay threads. `ctl` is filled
/// in place and held by the detached threads, so it must be stable storage in the
/// caller's frame (the boot frame). The agent's reply pipe is created here and wired
/// into both the agent (pipe_w) and the relay (pipe_r). Shared by both boot paths.
pub fn startControl(ctl: *ControlCtx, o: ControlOpts) void {
    // A control client can disconnect mid-stream (crash, kill, network blip) while the
    // relay or a reply is writing to its socket. Without this, that write raises SIGPIPE
    // and the default action kills the sandbox process - a client disconnect must never
    // take down the guest. Ignore it process-wide; the write then returns EPIPE and the
    // relay/command handler stops writing gracefully.
    hostutil.ignoreSigpipe();
    var pipe: [2]c_int = undefined;
    if (libc.pipe(&pipe) != 0) {
        std.debug.print("[control] pipe() failed; control socket disabled\n", .{});
        return;
    }
    // Non-blocking write end: the device (vCPU) thread pushes agent output here and must
    // NEVER block on a full pipe behind a wedged reader (pipePush handles EAGAIN). The read
    // end stays blocking - the relay thread parks on it between commands.
    hostutil.setNonblock(pipe[1]);
    o.agent.pipe_w = pipe[1];
    ctl.* = .{
        .vsdev = o.vsdev,
        .agent = o.agent,
        .meter = o.meter,
        .path = o.path,
        .pipe_r = pipe[0],
        .allocator = o.allocator,
        .stop = o.stop,
        .snapshot = o.snapshot,
        .gpu = o.gpu,
        .journal = o.journal,
        .probe = o.probe,
        .info = o.info,
    };
    o.agent.client = &ctl.client; // so the device thread can drop a wedged primary
    if (std.Thread.spawn(.{}, controlListener, .{ctl})) |t| t.detach() else |_| {}
    if (std.Thread.spawn(.{}, controlRelay, .{ctl})) |t| t.detach() else |_| {}
}

/// Concurrent control connections allowed: the platform's primary driver plus a
/// handful of read-only observers. The socket is owner-uid-gated, so this only
/// bounds an accidental fan-out, not an attacker.
const MAX_CLIENTS: u32 = 8;

/// How long a write to a control client may block on a full socket buffer before the relay
/// judges the client wedged and drops it. This is the worst-case window the pipe can stay
/// full (and thus the vCPU/device thread can be starved on the D3 lock behind it), so it is
/// kept SHORT: the control socket is local IPC drained at GB/s, and the pipe + socket buffers
/// (~320 KiB) already absorb any transient slowness, so a client still >320 KiB behind after
/// this long has genuinely stopped reading. The device's non-blocking pipePush bounds the
/// common case even tighter (~PIPE_WEDGE_MS); this is the robust backstop when a shutdown
/// fails to wake the relay's blocked write (macOS does not reliably interrupt it).
const RELAY_STALL_TIMEOUT_MS: u32 = 500;

/// How long the device (vCPU) thread applies backpressure on a full relay pipe before it
/// judges the reader wedged and drops it (pipePush). This is now the WORST-CASE vCPU stall a
/// wedged reader can cause (previously up to RELAY_STALL_TIMEOUT_MS): short, since a healthy
/// client drains the local-IPC pipe in microseconds, so a full pipe for this long means the
/// reader has genuinely stopped. The relay's SO_SNDTIMEO drop is the backstop.
const PIPE_WEDGE_MS: i32 = 100;

pub fn controlListener(ctx: *ControlCtx) void {
    const fd = libc.socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        std.debug.print("[control] socket() failed\n", .{});
        return;
    }
    _ = libc.unlink(ctx.path);
    var addr = SockaddrUn{};
    const p = std.mem.span(ctx.path);
    if (p.len + 1 > addr.path.len) { // + NUL; the fixed sun_path is 104 (macOS) / 108 (Linux)
        std.debug.print("[control] control_socket path too long ({d} > {d})\n", .{ p.len, addr.path.len - 1 });
        return;
    }
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
    // Bound writes to this client so a consumer that stops reading cannot wedge the relay
    // (and thereby stall the guest); a timed-out write makes the relay drop the client.
    hostutil.setSendTimeout(c, RELAY_STALL_TIMEOUT_MS);
    // Claim the primary slot if it is free; otherwise serve as an observer.
    const is_primary = ctx.client.cmpxchgStrong(-1, c, .acq_rel, .acquire) == null;
    // A fresh primary bumps the relay generation: if the previous primary left a command's
    // output still streaming, the relay skips that tail (to the next trailer) so it does not
    // land in this new primary's session and desync it.
    if (is_primary) _ = ctx.client_gen.fetchAdd(1, .release);
    // Release the primary slot on exit, but ONLY if we still hold it: a cmpxchg (not a bare
    // store) so a thread whose slot was already reclaimed - e.g. by the relay wedge-drop
    // (which uses the same cmpxchg at controlRelay), after which a new primary claimed it -
    // does not clobber that successor's claim (which would leave it a hung "ghost" primary).
    defer if (is_primary) {
        _ = ctx.client.cmpxchgStrong(c, -1, .acq_rel, .acquire);
    };
    if (is_primary) {
        if (ctx.agent.renders) |rm| rm.resetDiff(); // a fresh primary gets a full screen first
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
    // Command-boundary tracking, so a primary handoff mid-command doesn't leak the departed
    // primary's tail into the next primary's session. A raw 0x1e marks a trailer (the agent
    // escapes body bytes, so a 0x1e never appears in output), then digits, then \n.
    var in_trailer = false; // between a raw 0x1e and its \n
    var mid_command = false; // output has streamed since the last completed trailer
    var skipping = false; // discarding a departed primary's tail until the next trailer
    var my_gen = ctx.client_gen.load(.acquire);
    while (true) {
        const n = libc.read(ctx.pipe_r, &buf, buf.len);
        if (n <= 0) return;
        const bytes = buf[0..@intCast(n)];

        // A new primary claimed the slot. If a command was still streaming, skip its tail to
        // the next trailer boundary so this new primary starts clean (audit: relay tail leak).
        const gen = ctx.client_gen.load(.acquire);
        if (gen != my_gen) {
            my_gen = gen;
            if (mid_command) skipping = true;
        }

        // Scan the whole chunk to maintain trailer/command state; if skipping, find where the
        // in-flight command's trailer ends and deliver only what follows.
        var deliver_start: usize = 0;
        for (bytes, 0..) |b, i| {
            if (in_trailer) {
                if (b == '\n') {
                    in_trailer = false;
                    mid_command = false;
                    if (skipping) {
                        skipping = false;
                        deliver_start = i + 1; // discard through this trailer; deliver the rest
                    }
                }
            } else if (b == 0x1e) {
                in_trailer = true;
            } else {
                mid_command = true;
            }
        }
        if (skipping) continue; // whole chunk was the departed primary's tail: discard

        const out = bytes[deliver_start..];
        if (out.len == 0) continue;
        const c = ctx.client.load(.acquire);
        if (c < 0) continue; // no primary: drain+discard (keeps the vCPU live)
        const w = libc.write(c, out.ptr, out.len);
        if (w == @as(isize, @intCast(out.len))) {
            _ = ctx.meter.bytes_out.fetchAdd(out.len, .release);
        } else {
            // The primary is not draining (SO_SNDTIMEO-bounded write fell short): it stopped
            // reading for RELAY_STALL_TIMEOUT_MS. Drop it (cmpxchg so a freshly reconnected
            // primary is not clobbered; shutdown - not close - so its clientThread wakes and
            // frees the fd) so the relay keeps draining. The device thread's pipePush drops a
            // wedged reader even faster (~PIPE_WEDGE_MS), so this is a backstop.
            if (w > 0) _ = ctx.meter.bytes_out.fetchAdd(@intCast(w), .release);
            _ = ctx.client.cmpxchgStrong(c, -1, .acq_rel, .acquire);
            hostutil.shutdownRdwr(c);
            std.debug.print("[control] primary client wedged (no read in {d}ms); dropped to keep the guest live\n", .{RELAY_STALL_TIMEOUT_MS});
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

test "data-plane delivery ring is byte-exact across many wraparounds" {
    // The bridge's per-conn ring (bufAppend/bufDrain) is the lossless-delivery core: onRw
    // buffers into it, the device thread + pump drain it non-blocking to the unix socket.
    // Drive a small ring with random-length chunks through a socketpair and assert every
    // byte arrives in order (hundreds of wraparounds), independent of a live guest.
    var fds: [2]c_int = undefined;
    if (libc.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) != 0) return error.SkipZigTest;
    defer _ = libc.close(fds[0]);
    defer _ = libc.close(fds[1]);
    hostutil.setNonblock(fds[0]); // read end: so the final drain-check read returns EAGAIN, not blocks
    hostutil.setNonblock(fds[1]); // write end: bufDrain uses trySend (must be non-blocking)
    hostutil.setSendBuf(fds[1], 4 << 20); // hold the whole test's bytes without a reader

    var ring: [64]u8 = undefined; // small -> forces frequent wraparound
    var br = DataBridge{ .vsdev = undefined, .path = undefined }; // rate_bps=0: unlimited (no pacing)
    var e = DataBridge.Entry{ .active = true, .unix_fd = fds[1], .buf = &ring };
    var expected: [80 * 1024]u8 = undefined;
    var elen: usize = 0;
    var b: u8 = 0;
    var round: usize = 0;
    while (round < 3000) : (round += 1) {
        const room = e.buf.len - e.bc;
        const n = @min(round % 23, room);
        var chunk: [23]u8 = undefined;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            chunk[i] = b;
            b +%= 1;
        }
        try testing.expect(DataBridge.bufAppend(&e, chunk[0..n]));
        @memcpy(expected[elen..][0..n], chunk[0..n]);
        elen += n;
        _ = br.bufDrain(&e, true); // opportunistic non-blocking drain (like the device thread)
    }
    while (e.bc > 0) if (br.bufDrain(&e, false) == 0) break; // final flush (like teardown)

    var got: [80 * 1024]u8 = undefined;
    var glen: usize = 0;
    while (true) {
        const r = libc.read(fds[0], @ptrCast(got[glen..].ptr), got.len - glen);
        if (r <= 0) break; // EAGAIN once drained
        glen += @intCast(r);
    }
    try testing.expectEqualSlices(u8, expected[0..elen], got[0..glen]);
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

    // The WIRE SHAPE is the load-bearing contract for a consumer's read loop. In v2 EVERY
    // command/ack reply is framed with the 0x1e<exit>\n trailer (reports + OK acks -> exit 0;
    // control-plane ERR -> exit -1, a negative that a guest exit 0..255 can never collide
    // with), so a consumer reads any of them with one loop and no timing heuristic. Only the
    // streamed replies (logs/screen/binary) stay self-delimiting. Lock the shape here so a
    // refactor can't drop a trailer (breaking consumers) or misassign the exit. Matches
    // tools/nether-ctl.c is_framed() and docs/control-protocol.md.
    const FRAME_OK = "\x1e0\n";
    const FRAME_ERR = "\x1e-1\n";

    // __info__: versioned capabilities. FRAMED (exit 0).
    controlCommand(&ctx, w, "__info__\n", true);
    {
        const out = drain(fds[0], &rbuf);
        try testing.expect(std.mem.indexOf(u8, out, "proto_version=2") != null);
        try testing.expect(std.mem.endsWith(u8, out, FRAME_OK));
    }

    // __help__: discoverable command list with the version banner. FRAMED (exit 0).
    controlCommand(&ctx, w, "__help__\n", true);
    {
        const out = drain(fds[0], &rbuf);
        try testing.expect(std.mem.indexOf(u8, out, "control protocol v2") != null);
        try testing.expect(std.mem.indexOf(u8, out, "__shutdown__") != null);
        try testing.expect(std.mem.indexOf(u8, out, "__put__") != null);
        try testing.expect(std.mem.endsWith(u8, out, FRAME_OK));
    }

    // __stats__: the metered dimensions. FRAMED (exit 0).
    controlCommand(&ctx, w, "__stats__\n", true);
    {
        const out = drain(fds[0], &rbuf);
        try testing.expect(std.mem.indexOf(u8, out, "cpu_ms=") != null);
        try testing.expect(std.mem.endsWith(u8, out, FRAME_OK));
    }

    // __events__: the journal's boot lifecycle event is visible. STREAMED (self-delimiting
    // log, no 0x1e trailer - a consumer reads it in streamed mode, not to a frame).
    controlCommand(&ctx, w, "__events__\n", true);
    {
        const out = drain(fds[0], &rbuf);
        try testing.expect(std.mem.indexOf(u8, out, "LIFE boot") != null);
        try testing.expect(std.mem.indexOfScalar(u8, out, 0x1e) == null);
    }

    // Reserved namespace: an unknown __verb__ is rejected. v2: FRAMED as a control error
    // (body "ERR ...", exit -1) - no bare/framed ambiguity for the consumer.
    controlCommand(&ctx, w, "__bogus__\n", true);
    {
        const out = drain(fds[0], &rbuf);
        try testing.expect(std.mem.indexOf(u8, out, "ERR unknown command") != null);
        try testing.expect(std.mem.endsWith(u8, out, FRAME_ERR)); // control error: exit -1
    }

    // Control byte in a command is rejected fail-closed (it could forge a frame). FRAMED ERR.
    controlCommand(&ctx, w, "ls \x1e forged\n", true);
    {
        const out = drain(fds[0], &rbuf);
        try testing.expect(std.mem.indexOf(u8, out, "ERR control byte") != null);
        try testing.expect(std.mem.endsWith(u8, out, FRAME_ERR));
    }

    // Observer gate: a non-primary client cannot drive the sandbox; stop must NOT fire.
    // FRAMED as a control error (exit -1).
    controlCommand(&ctx, w, "__shutdown__\n", false);
    {
        const out = drain(fds[0], &rbuf);
        try testing.expect(std.mem.indexOf(u8, out, "ERR read-only observer") != null);
        try testing.expect(std.mem.endsWith(u8, out, FRAME_ERR));
    }
    try testing.expect(!spy.stopped);

    // Primary may: acked, and the injected stop fires exactly once here. v2: FRAMED OK ack
    // (exit 0) - so a consumer reads shutdown/snapshot/put/get with the same framed loop.
    controlCommand(&ctx, w, "__shutdown__\n", true);
    {
        const out = drain(fds[0], &rbuf);
        try testing.expect(std.mem.indexOf(u8, out, "OK shutting down") != null);
        try testing.expect(std.mem.endsWith(u8, out, FRAME_OK));
    }
    try testing.expect(spy.stopped);
}

test "control: a command to a never-connecting guest agent fails fast (bounded wait)" {
    // A driving command waits for the in-guest agent (conn_id), but only up to
    // agent_wait_ms - a broken/absent guest must not block the control thread forever.
    var core = Core{};
    core.init(256, 1, 0); // conn_id stays -1 (no agent connected)
    var dummy_vsdev: nether.VsockDev = undefined; // never reached: we time out first
    const NoopStop = struct {
        fn stop(_: *anyopaque) void {}
    };
    var ctx = ControlCtx{
        .vsdev = &dummy_vsdev,
        .agent = &core.agent,
        .meter = &core.meter,
        .path = "/tmp/nether-test-unused.sock",
        .pipe_r = -1,
        .allocator = testing.allocator,
        .stop = .{ .ctx = &core, .func = NoopStop.stop },
        .agent_wait_ms = 60, // tiny so the test is fast
    };
    var fds: [2]c_int = undefined;
    if (libc.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) != 0) return error.SkipZigTest;
    defer _ = libc.close(fds[0]);
    defer _ = libc.close(fds[1]);
    controlCommand(&ctx, fds[1], "echo hi\n", true); // a shell command -> hits the wait
    var rbuf: [256]u8 = undefined;
    const n = libc.read(fds[0], rbuf[0..].ptr, rbuf.len);
    try testing.expect(n > 0);
    try testing.expect(std.mem.indexOf(u8, rbuf[0..@intCast(n)], "ERR agent not connected") != null);
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
    try testing.expect(std.mem.indexOf(u8, out, "x402=off\n") != null); // settlement mode off by default
    try testing.expect(std.mem.indexOfScalar(u8, out, 0x1e) != null); // exit frame

    // With settlement mode on, __info__ advertises it so the client knows the sandbox is billable.
    const billable = SandboxInfo{ .cpus = 1, .x402 = true };
    const out2 = buf[0..billable.report(&buf)];
    try testing.expect(std.mem.indexOf(u8, out2, "x402=on\n") != null);
}

test "x402 toggle selects the teardown record framing (settlement vs telemetry)" {
    // The platform keys billing off the record prefix, so the two must never be confused:
    // off (general workload, the default) is operational telemetry; on is the billable
    // settlement. The metered fields are identical either way (the meter is unaffected).
    var c = Core{};
    c.init(256, 1, 0);
    try testing.expect(!c.x402); // default off
    try testing.expectEqualStrings("final usage", c.recordKind());
    c.x402 = true;
    try testing.expectEqualStrings("x402 settlement", c.recordKind());
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
    var rootbuf: [PATH_MAX]u8 = undefined;
    const root_c = libc.realpath(jail, &rootbuf) orelse return error.SkipZigTest;
    const root = std.mem.span(root_c);

    var out: [PATH_MAX]u8 = undefined;
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

test "create-write refuses a symlink at the basename (no jail escape via O_NOFOLLOW)" {
    // jailedPath confines the path STRING (and resolves the parent), but a pre-existing
    // symlink AT the basename pointing outside the jail would let a create-write follow it
    // and truncate the target. createTruncNoFollow (used by __get__ and __snapshot__)
    // refuses that symlink at open time. This proves the hole is closed.
    const c = struct {
        extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
        extern "c" fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) c_int;
        extern "c" fn rmdir(path: [*:0]const u8) c_int;
    };
    const jail = "/tmp/nether-nofollow-test";
    const target = "/tmp/nether-nofollow-target.txt"; // the OUTSIDE file an escape would hit
    const evil = jail ++ "/evil"; // a symlink inside the jail -> the outside target
    const good = jail ++ "/good.txt"; // a normal new file inside the jail
    _ = libc.unlink(evil);
    _ = libc.unlink(good);
    _ = libc.unlink(target);
    _ = c.rmdir(jail);
    if (c.mkdir(jail, 0o700) != 0) return error.SkipZigTest;
    defer {
        _ = libc.unlink(evil);
        _ = libc.unlink(good);
        _ = libc.unlink(target);
        _ = c.rmdir(jail);
    }
    // Seed the outside target with content we can check was NOT truncated.
    const tfd = libc.open(target, 0x0001 | 0x0200, @as(c_int, 0o600)); // O_WRONLY|O_CREAT
    if (tfd < 0) return error.SkipZigTest;
    try testing.expect(writeAll(tfd, "PRECIOUS"));
    _ = libc.close(tfd);
    if (c.symlink(target, evil) != 0) return error.SkipZigTest;

    var root: [PATH_MAX]u8 = undefined;
    const root_c = libc.realpath(jail, &root) orelse return error.SkipZigTest;
    var out: [PATH_MAX]u8 = undefined;
    // jailedPath ACCEPTS the path string (basename is a plain name inside the jail)...
    const hp = jailedPath(&out, std.mem.span(root_c), evil, true) orelse return error.SkipZigTest;
    // ...but the create-write open refuses to follow the symlink (ELOOP -> fd < 0).
    const fd = hostutil.createTruncNoFollow(hp);
    try testing.expect(fd < 0);
    if (fd >= 0) _ = libc.close(fd);
    // And the outside target is intact (was never truncated).
    const data = try readFileMac(testing.allocator, target);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("PRECIOUS", data);

    // A normal create inside the jail still works through the same helper.
    var gout: [PATH_MAX]u8 = undefined;
    const gp = jailedPath(&gout, std.mem.span(root_c), good, true) orelse return error.SkipZigTest;
    const gfd = hostutil.createTruncNoFollow(gp);
    try testing.expect(gfd >= 0);
    if (gfd >= 0) _ = libc.close(gfd);
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

test "a control-client disconnect mid-write does not kill the process (SIGPIPE ignored)" {
    // Models the primary platform client vanishing while the relay writes its command
    // output: the write hits a broken socket. Without ignoreSigpipe the default SIGPIPE
    // action would terminate THIS test process, so the test reaching its assertion alive
    // is the proof - writeAll instead surfaces the broken pipe as a clean false.
    hostutil.ignoreSigpipe();
    var fds: [2]c_int = undefined;
    if (libc.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) != 0) return error.SkipZigTest;
    _ = libc.close(fds[1]); // the "client" disconnects
    var failed = false;
    var i: usize = 0;
    while (i < 1000) : (i += 1) { // bounded: the broken pipe surfaces within a few writes
        if (!writeAll(fds[0], "x" ** 4096)) {
            failed = true;
            break;
        }
    }
    _ = libc.close(fds[0]);
    try testing.expect(failed); // EPIPE surfaced as a false, and the process is still alive
}

test "setSendTimeout bounds a write to a non-draining client (relay can't be wedged forever)" {
    // The relay writes the agent's reply to the primary client. If the client stops
    // reading, that write must not block forever (it would stall pipe -> agent -> vCPU and
    // freeze the guest). With SO_SNDTIMEO the write returns once the buffer is full and the
    // timeout elapses. The peer (fds[1]) stays OPEN but unread, so this is a stall, not a
    // disconnect. The test reaching its end at all proves the write didn't hang forever.
    var fds: [2]c_int = undefined;
    if (libc.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) != 0) return error.SkipZigTest;
    defer _ = libc.close(fds[0]);
    defer _ = libc.close(fds[1]);
    hostutil.setSendTimeout(fds[0], 200); // 200ms cap (vs the 5s production value)
    var blob: [65536]u8 = undefined;
    @memset(&blob, 'x');
    var bounded = false;
    var i: usize = 0;
    while (i < 4000) : (i += 1) { // bounded so a broken timeout shows as a hang, not a spin
        const w = libc.write(fds[0], &blob, blob.len);
        if (w < @as(isize, @intCast(blob.len))) { // buffer full + timeout -> short/EAGAIN
            bounded = true;
            break;
        }
    }
    try testing.expect(bounded);
}

test "agent reply relay survives hostile guest streams (exit-scan + output cap)" {
    // The in-guest agent's reply bytes are attacker-controlled: raw command output then a
    // 0x1e<exit>\n trailer. The host SCANS that stream for the trailer to record exit codes
    // (auditRecv -> the command audit log) and RELAYS it under a per-command output cap
    // (relayCapped), both byte-at-a-time across arbitrary chunk boundaries. Drive random and
    // trailer-shaped streams in random splits, interleaved with command "forwards", and
    // assert no safety trip: the fixed exit-scan buffer never overflows and the audit ring
    // head stays valid for any byte pattern.
    const devnull = libc.open("/dev/null", 0x0001, @as(c_int, 0)); // O_WRONLY; relay sink
    if (devnull < 0) return error.SkipZigTest;
    defer _ = libc.close(devnull);

    var a = AgentCtx{ .pipe_w = devnull, .max_output = 64 };
    var prng = std.Random.DefaultPrng.init(0xA9E2_C0DE);
    const rand = prng.random();
    var round: usize = 0;
    while (round < 30000) : (round += 1) {
        // Sometimes "open" a command so a trailer has a pending slot to commit against.
        if (rand.boolean()) {
            var nb: [40]u8 = undefined;
            a.auditForward(std.fmt.bufPrint(&nb, "cmd{d}", .{round}) catch unreachable);
        }
        // Build a hostile reply: often trailer-shaped (body + 0x1e + digits + \n, where the
        // digits are sometimes overlong/garbage/negative), sometimes pure random bytes.
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        if (rand.boolean()) {
            len = rand.uintLessThan(usize, 200);
            rand.bytes(buf[0..len]);
            if (len < buf.len) {
                buf[len] = 0x1e;
                len += 1;
            }
            const digits = rand.uintLessThan(usize, 40); // > the 16-byte exit buffer
            var d: usize = 0;
            while (d < digits and len < buf.len) : (d += 1) {
                buf[len] = "0123456789-+xX\r"[rand.uintLessThan(usize, 15)];
                len += 1;
            }
            if (len < buf.len) {
                buf[len] = '\n';
                len += 1;
            }
        } else {
            len = rand.uintLessThan(usize, buf.len);
            rand.bytes(buf[0..len]);
        }
        // Feed in random chunks through BOTH observers, mirroring agentEvent's .recv order.
        var off: usize = 0;
        while (off < len) {
            const chunk = 1 + rand.uintLessThan(usize, 17);
            const end = @min(off + chunk, len);
            a.auditRecv(buf[off..end]);
            a.relayCapped(buf[off..end]);
            off = end;
        }
        // Invariants that must hold for ANY byte pattern: the exit-scan accumulator stays
        // within its fixed buffer, and the audit ring head is always a valid index.
        try testing.expect(a.audit_exit_len <= a.audit_exit.len);
        try testing.expect(a.cmd_head < CMD_LOG_CAP);
    }
    // The audit log still serializes cleanly after the assault.
    var out: [16384]u8 = undefined;
    std.mem.doNotOptimizeAway(a.cmdLog(&out));
}

// Mirror of tools/agent.c write_escaped, for the R2b framing tests below.
fn escapeBody(in: []const u8, out: []u8) usize {
    var n: usize = 0;
    for (in) |b| {
        if (b == OUT_DELIM or b == OUT_ESC) {
            out[n] = OUT_ESC;
            out[n + 1] = b ^ OUT_ESC_XOR;
            n += 2;
        } else {
            out[n] = b;
            n += 1;
        }
    }
    return n;
}

test "R2b: an escaped body cannot forge the exit trailer (audit records the real exit)" {
    // Command stdout literally contains a trailer-shaped sequence (0x1e '0' \n). Because the
    // agent delimiter-escapes the body, that 0x1e goes on the wire as 0x1f 0x5e - so only the
    // REAL trailer (0x1e '7' \n) carries a raw 0x1e. The host trailer scanner must record 7.
    var wire: [64]u8 = undefined;
    var n = escapeBody("hi\x1e0\n", wire[0..]); // a forged trailer buried in the output
    const tail = "\x1e7\n"; // the real, raw trailer
    @memcpy(wire[n .. n + tail.len], tail);
    n += tail.len;
    try testing.expect(std.mem.indexOfScalar(u8, wire[0 .. n - tail.len], OUT_DELIM) == null); // body carries no raw delim

    var a = AgentCtx{};
    a.auditForward("run");
    for (wire[0..n]) |b| a.auditRecv(&[_]u8{b}); // byte-at-a-time: exercise the streaming scanner
    const got = a.cmd_log[(a.cmd_head + CMD_LOG_CAP - 1) % CMD_LOG_CAP];
    try testing.expectEqual(@as(i32, 7), got.exit);

    // Contrast: the same bytes UNescaped (i.e. the pre-R2b wire) desync to the forged exit 0 -
    // this is exactly the bug the escape closes.
    var b2 = AgentCtx{};
    b2.auditForward("run");
    b2.auditRecv("hi\x1e0\n\x1e7\n");
    const bad = b2.cmd_log[(b2.cmd_head + CMD_LOG_CAP - 1) % CMD_LOG_CAP];
    try testing.expectEqual(@as(i32, 0), bad.exit);
}

test "data-plane bridge survives hostile event/lifecycle sequences" {
    // Deterministic companion to "fuzz: data-plane bridge" (fuzz.zig): hammer the bridge
    // state machine with random register/event/teardown ops and assert it never crashes,
    // OOBs, or leaves the table over-full. Runs on every `zig test`.
    var prng = std.Random.DefaultPrng.init(0xB21D6E5);
    const rand = prng.random();
    var round: usize = 0;
    while (round < 3000) : (round += 1) {
        var buf: [64]u8 = undefined;
        const n = rand.uintLessThan(usize, buf.len + 1);
        rand.bytes(buf[0..n]);
        fuzzBridge(buf[0..n]);
    }
}

test "outUnescape round-trips and streams across a split escape lead" {
    const orig = "a\x1eb\x1fc\x1e\x1f";
    var esc: [32]u8 = undefined;
    const en = escapeBody(orig, esc[0..]);
    try testing.expect(std.mem.indexOfScalar(u8, esc[0..en], OUT_DELIM) == null); // no raw delim survives

    var out: [32]u8 = undefined;
    var e = false;
    const m = outUnescape(esc[0..en], out[0..], &e);
    try testing.expect(!e);
    try testing.expectEqualSlices(u8, orig, out[0..m]);

    // Split the wire right after an escape lead so `esc` must carry the mid-escape across calls.
    var split: usize = 1;
    for (esc[0..en], 0..) |b, idx| {
        if (b == OUT_ESC) {
            split = idx + 1;
            break;
        }
    }
    var out2: [32]u8 = undefined;
    var e2 = false;
    var m2 = outUnescape(esc[0..split], out2[0..], &e2);
    try testing.expect(e2); // mid-escape carried to the next call
    m2 += outUnescape(esc[split..en], out2[m2..], &e2);
    try testing.expect(!e2);
    try testing.expectEqualSlices(u8, orig, out2[0..m2]);
}
