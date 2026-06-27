//! SMP coordination: the shared state behind PSCI CPU_ON, which is how an arm64
//! guest brings secondary cores online. The boot CPU calls
//! `PSCI_CPU_ON(target_mpidr, entry_point, context_id)`; we record the entry for
//! the target core and release its (already-created, parked) vCPU thread to start
//! executing there with x0 = context_id.
//!
//! Hypervisor-agnostic: the backend run loop calls into `Smp.cpuOn`/`affinityInfo`
//! from its PSCI handler, and each secondary vCPU thread waits on its `Cpu.started`
//! flag. On HVF a vCPU is bound to the thread that created it, so every core
//! (boot and secondary) creates and runs its own vCPU on its own thread; this
//! module is just the rendezvous.

const std = @import("std");

/// PSCI return values (SMC Calling Convention, signed).
pub const PSCI_SUCCESS: i64 = 0;
pub const PSCI_NOT_SUPPORTED: i64 = -1;
pub const PSCI_INVALID_PARAMETERS: i64 = -2;
pub const PSCI_ALREADY_ON: i64 = -4;

/// PSCI AFFINITY_INFO states.
pub const AFFINITY_ON: i64 = 0;
pub const AFFINITY_OFF: i64 = 1;

/// MPIDR affinity bits that identify a core (Aff3 in [39:32], Aff2..0 in [23:0]);
/// the RES1/U/MT flag bits are masked out, matching the kernel's MPIDR_HWID_BITMASK.
pub const MPIDR_HWID_MASK: u64 = 0xff00_ffff_ff;

pub const Cpu = struct {
    mpidr: u64,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    entry: u64 = 0,
    context: u64 = 0,
};

pub const Smp = struct {
    cpus: []Cpu,

    /// PSCI CPU_ON: release the target core to run at `entry` with x0 = `context`.
    pub fn cpuOn(self: *Smp, target: u64, entry: u64, context: u64) i64 {
        const cpu = self.find(target) orelse return PSCI_INVALID_PARAMETERS;
        if (cpu.started.load(.acquire)) return PSCI_ALREADY_ON;
        cpu.entry = entry;
        cpu.context = context;
        cpu.started.store(true, .release); // release: entry/context visible first
        return PSCI_SUCCESS;
    }

    pub fn affinityInfo(self: *Smp, target: u64) i64 {
        const cpu = self.find(target) orelse return PSCI_INVALID_PARAMETERS;
        return if (cpu.started.load(.acquire)) AFFINITY_ON else AFFINITY_OFF;
    }

    fn find(self: *Smp, target: u64) ?*Cpu {
        const want = target & MPIDR_HWID_MASK;
        for (self.cpus) |*c| {
            if ((c.mpidr & MPIDR_HWID_MASK) == want) return c;
        }
        return null;
    }
};

// --- tests -----------------------------------------------------------------

test "cpuOn releases a parked core and is idempotent-rejecting" {
    var cpus = [_]Cpu{
        .{ .mpidr = 0x8000_0000 }, // boot cpu, id 0
        .{ .mpidr = 0x8000_0001 }, // id 1
    };
    var smp = Smp{ .cpus = &cpus };

    // Target by the affinity the DT advertises (the bare id, no flag bits).
    try std.testing.expectEqual(PSCI_SUCCESS, smp.cpuOn(1, 0x4020_0000, 0xabc));
    try std.testing.expect(cpus[1].started.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0x4020_0000), cpus[1].entry);
    try std.testing.expectEqual(@as(u64, 0xabc), cpus[1].context);
    try std.testing.expectEqual(AFFINITY_ON, smp.affinityInfo(1));

    // Turning it on again fails; an unknown target is rejected.
    try std.testing.expectEqual(PSCI_ALREADY_ON, smp.cpuOn(1, 0, 0));
    try std.testing.expectEqual(PSCI_INVALID_PARAMETERS, smp.cpuOn(9, 0, 0));
    try std.testing.expectEqual(AFFINITY_OFF, smp.affinityInfo(0));
}
