//! Shared platform-layer wiring used by BOTH boot paths (macBootLinux on HVF,
//! linuxMain on KVM), so the agent control plane is ported once and the two
//! backends can't drift. First piece: the lifecycle watchdogs. As the Linux port
//! lands (docs/linux-platform-port.md #2/#3), the rest of the platform init -
//! control socket, metering, journal, render - joins this module.
//!
//! Everything here is backend-agnostic by construction: the one thing that differs
//! per backend - how you force the guest to stop - is injected as a `Stop`. On HVF
//! that's hv_vcpus_exit (via control.stopSandbox); on KVM it will be signalling the
//! vCPU thread so KVM_RUN returns EINTR (the open question in the port plan).

const std = @import("std");
const hostutil = @import("../common/hostutil.zig");

const nowMs = hostutil.nowMs;
const usleep = hostutil.usleep;
const processCpuMs = hostutil.processCpuMs;

/// Set by the SIGTERM handler (async-signal-safe: an atomic store only), polled by
/// `Watchdogs.sigLoop` which performs the real stop. One nether process serves one
/// sandbox, so a single process-global flag is correct.
var term_requested = std.atomic.Value(bool).init(false);

/// SIGTERM handler. Does nothing but record the request - formatting/printing/stopping
/// are not async-signal-safe, so they happen in `sigLoop`.
fn onTerminate(_: c_int) callconv(.c) void {
    term_requested.store(true, .release);
}

/// A backend-agnostic guest stop: force the guest down its PSCI-poweroff path so the
/// run loop returns `.shutdown` and the process exits cleanly. The `ctx` outlives the
/// caller (the watchdog threads are detached), so it must point at stable storage.
pub const Stop = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque) void,
    pub fn call(self: Stop) void {
        self.func(self.ctx);
    }
};

/// A backend-agnostic on-demand snapshot: quiesce the guest, capture full machine
/// state, and write a fork-source base file to `fd`, then resume - so the platform
/// can pre-bake base images by driving a sandbox to a ready state and issuing
/// `__snapshot__`. Returns true on success. The `ctx` outlives the caller, so it must
/// point at stable storage (the boot frame's SnapCtx). HVF only; the KVM path leaves
/// this null until KVM snapshot lands.
///
/// The destination arrives as an ALREADY-OPEN fd (plus `path`, for log messages only):
/// the control plane opens it via the pinned jail-root dirfd (hostutil.openJailedAt),
/// so the snapshot write cannot be redirected out of the transfer jail by a path
/// component swapped between the containment check and the open (TOCTOU). The caller
/// owns the fd (closes it, and unlinks the file if the capture fails).
pub const Snapshotter = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque, fd: c_int, path: [*:0]const u8) bool,
    pub fn call(self: Snapshotter, fd: c_int, path: [*:0]const u8) bool {
        return self.func(self.ctx, fd, path);
    }
};

/// Lifecycle watchdogs (govern): the runtime budget (a hard wall-clock cap) and the
/// idle timeout (reclaim a sandbox with no control-plane activity). Both stop the
/// guest via the injected `Stop`, so the module is identical on both backends.
/// Storage must live in the caller's frame (arm() spawns detached threads that hold
/// `self` for the VM's lifetime); pass `&watchdogs` and do not move it after arm().
pub const Watchdogs = struct {
    stop: Stop,
    activity: ?*std.atomic.Value(i64) = null, // control-plane activity; required only for idle
    start_ms: i64 = 0, // set by arm()
    runtime_ms: i64 = 0, // hard wall-clock cap (0 = unlimited)
    idle_ms: i64 = 0, // idle reclamation (0 = disabled; needs `activity`)
    cpu_ms: i64 = 0, // hard CPU-time cap (0 = unlimited): total process CPU consumed

    /// Start the clock and spawn the enabled watchdog threads. A budget of 0 means
    /// that watchdog is not armed. The idle watchdog also needs `activity` (the runtime
    /// budget does not), so a bare VMM can arm just the runtime cap.
    pub fn arm(self: *Watchdogs) void {
        self.start_ms = nowMs();
        // A process-manager / platform SIGTERM (forced reclaim) must drain through the
        // normal teardown - power the guest off so the run loop returns and the final
        // usage bill is emitted - not kill the process silently with no settlement record.
        // The handler only sets an atomic flag (async-signal-safe); sigLoop does the stop
        // in normal context. Always armed (unlike the budgets), even on a bare VMM.
        _ = hostutil.libc.signal(15, @intFromPtr(&onTerminate)); // SIGTERM = 15 (macOS + Linux)
        if (std.Thread.spawn(.{}, sigLoop, .{self})) |t| t.detach() else |_| {}
        if (self.runtime_ms > 0) {
            if (std.Thread.spawn(.{}, runtimeLoop, .{self})) |t| t.detach() else |_| {}
            std.debug.print("[nether] runtime budget armed: {d}s\n", .{@divTrunc(self.runtime_ms, 1000)});
        }
        if (self.idle_ms > 0) {
            if (self.activity) |act| {
                act.store(self.start_ms, .release); // count idle from boot
                if (std.Thread.spawn(.{}, idleLoop, .{self})) |t| t.detach() else |_| {}
                std.debug.print("[nether] idle timeout armed: {d}s\n", .{@divTrunc(self.idle_ms, 1000)});
            }
        }
        if (self.cpu_ms > 0) {
            if (std.Thread.spawn(.{}, cpuLoop, .{self})) |t| t.detach() else |_| {}
            std.debug.print("[nether] cpu budget armed: {d}s\n", .{@divTrunc(self.cpu_ms, 1000)});
        }
    }

    /// Stop once the wall-clock budget elapses.
    fn runtimeLoop(self: *Watchdogs) void {
        while (nowMs() - self.start_ms < self.runtime_ms) _ = usleep(200_000); // ~5 Hz
        std.debug.print("\n[nether] runtime budget ({d}s) reached; stopping sandbox\n", .{@divTrunc(self.runtime_ms, 1000)});
        self.stop.call();
    }

    /// Stop once no control-plane activity has occurred for `idle_ms`. Only spawned
    /// when `activity` is set, so the unwrap is safe.
    fn idleLoop(self: *Watchdogs) void {
        const activity = self.activity.?;
        while (nowMs() - activity.load(.acquire) < self.idle_ms) _ = usleep(200_000); // ~5 Hz
        std.debug.print("\n[nether] idle timeout ({d}s) reached; stopping sandbox\n", .{@divTrunc(self.idle_ms, 1000)});
        self.stop.call();
    }

    /// Stop the sandbox when a SIGTERM has been requested. The signal handler only flips
    /// an atomic flag (the only async-signal-safe option); this loop, in normal context,
    /// performs the real stop via the injected Stop - so a forced reclaim still powers the
    /// guest off cleanly and the caller emits the final usage bill, instead of the process
    /// dying with no settlement record.
    fn sigLoop(self: *Watchdogs) void {
        while (!term_requested.load(.acquire)) _ = usleep(100_000); // ~10 Hz
        std.debug.print("\n[nether] SIGTERM received; stopping sandbox (final usage bill follows)\n", .{});
        self.stop.call();
    }

    /// Stop once the sandbox's total CPU time exceeds `cpu_ms`. Unlike the wall-clock
    /// runtime budget, this charges only actual compute (getrusage process CPU), so an
    /// idle sandbox is never billed out while a CPU-pinning one is caught quickly. The
    /// signal is the same `cpu_ms` reported by __stats__.
    fn cpuLoop(self: *Watchdogs) void {
        while (@as(i64, @intCast(processCpuMs())) < self.cpu_ms) _ = usleep(200_000); // ~5 Hz
        std.debug.print("\n[nether] cpu budget ({d}s) reached; stopping sandbox\n", .{@divTrunc(self.cpu_ms, 1000)});
        self.stop.call();
    }
};

// --- tests -----------------------------------------------------------------
const testing = std.testing;

test "injected Stop dispatches to the backend stop with its context" {
    const Spy = struct {
        hit: bool = false,
        fn stop(p: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p));
            self.hit = true;
        }
    };
    var spy = Spy{};
    const s = Stop{ .ctx = &spy, .func = Spy.stop };
    try testing.expect(!spy.hit);
    s.call();
    try testing.expect(spy.hit); // the watchdog's stop reaches the backend, ctx intact
}

test "SIGTERM is caught and requests a graceful stop (not a silent death)" {
    // Installing the handler then raising SIGTERM must NOT terminate this test process
    // (the default action) - the handler catches it and flips the flag, which sigLoop
    // would turn into a clean stop + final bill. The test reaching its assertion alive is
    // itself the proof the signal was handled.
    _ = hostutil.libc.signal(15, @intFromPtr(&onTerminate));
    term_requested.store(false, .release);
    try testing.expect(hostutil.libc.raise(15) == 0);
    try testing.expect(term_requested.load(.acquire));
}
