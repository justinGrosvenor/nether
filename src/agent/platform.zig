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

    /// Start the clock and spawn the enabled watchdog threads. A budget of 0 means
    /// that watchdog is not armed. The idle watchdog also needs `activity` (the runtime
    /// budget does not), so a bare VMM can arm just the runtime cap.
    pub fn arm(self: *Watchdogs) void {
        self.start_ms = nowMs();
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
