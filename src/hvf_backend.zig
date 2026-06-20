//! HVF hypervisor backend (macOS / Apple Silicon, aarch64 guests). Peer of the
//! KVM backend, selected at comptime on macOS by backend.zig.
//!
//! STATUS: first light. Implements the backend interface against Apple's
//! Hypervisor.framework: hv_vm_create + hv_vm_map for guest RAM, hv_vcpu_create
//! and a run loop that decodes data-abort (MMIO) exits and dispatches them to
//! the device bus, and an aarch64 boot entry (PC + PSTATE). The framework GIC,
//! PSCI, the generic timer, and the Image+DTB boot path land in later chunks
//! (see docs/roadmap.md aarch64 track); for now a guest signals stop with an
//! MMIO write that a device turns into a power request, like the x86 path.
//!
//! The x86 boot-entry methods exist only as inert stubs so the shared Vcpu type
//! and the (x86-only) PVH loader keep compiling on macOS; they never run here.

const std = @import("std");
const io = @import("io.zig");
const pwr = @import("power.zig");
const hvf = @import("hvf.zig");
const arm = @import("memmap_arm.zig");
const hvtypes = @import("hvtypes.zig");
const smp = @import("smp.zig");

const StopReason = hvtypes.StopReason;
const Error = hvtypes.Error;

/// ESR_EL2 exception classes we care about.
const EC_DATA_ABORT_LOWER: u64 = 0x24;
const EC_HVC: u64 = 0x16; // HVC instruction from AArch64 (PSCI firmware calls)
const EC_WFX: u64 = 0x01; // trapped WFI/WFE (idle); resume past it
const EC_SYSREG: u64 = 0x18; // trapped MSR/MRS/system reg (emulate RAZ/WI)

/// PSCI function IDs (the guest's "firmware" for power; the arm64 analog of the
/// ACPI PM block). The guest calls these via `hvc #0` with the FID in w0/x0.
const PSCI_VERSION: u64 = 0x8400_0000;
const PSCI_CPU_OFF: u64 = 0x8400_0002;
const PSCI_CPU_ON_32: u64 = 0x8400_0003;
const PSCI_CPU_ON_64: u64 = 0xc400_0003;
const PSCI_AFFINITY_INFO_32: u64 = 0x8400_0004;
const PSCI_AFFINITY_INFO_64: u64 = 0xc400_0004;
const PSCI_FEATURES: u64 = 0x8400_000a;
const PSCI_SYSTEM_OFF: u64 = 0x8400_0008;
const PSCI_SYSTEM_RESET: u64 = 0x8400_0009;
const PSCI_VERSION_1_0: u64 = 0x0001_0000; // major 1, minor 0
const PSCI_NOT_SUPPORTED: u64 = @bitCast(@as(i64, -1));

/// Initial PSTATE: EL1h (M[3:0]=0b0101) with D,A,I,F masked (0xF<<6).
const CPSR_EL1H_MASKED: u64 = 0x3c5;

fn ok(r: hvf.hv_return_t, comptime what: []const u8) Error!void {
    if (r != hvf.HV_SUCCESS) {
        std.debug.print("[nether] {s} failed: hv_return=0x{x}\n", .{ what, @as(u32, @bitCast(r)) });
        return error.SyscallFailed;
    }
}

pub const Vm = struct {
    /// GIC region sizes the framework reported (used to fill the DTB so the
    /// kernel's GIC reg matches what hv_gic actually placed).
    gicd_size: u64 = arm.gicd_size,
    gicr_size: u64 = arm.gicr_size, // whole redistributor region (DTB GICR reg size)
    /// The GIC SPI range the framework reserved for MSIs (the top of its SPI
    /// space); the DTB's v2m frame advertises exactly this so the guest allocates
    /// MSI vectors the framework will accept via hv_gic_send_msi.
    msi_spi_base: u32 = 0,
    msi_spi_count: u32 = 0,

    pub fn init() Error!Vm {
        try ok(hvf.hv_vm_create(null), "hv_vm_create");
        return .{};
    }

    pub fn deinit(self: *Vm) void {
        _ = self;
        _ = hvf.hv_vm_destroy();
    }

    /// mmap host RAM and map it into the guest IPA space at `guest_phys`.
    pub fn mapMemory(self: *Vm, slot: u32, guest_phys: u64, size: usize) Error![]u8 {
        _ = self;
        _ = slot;
        const mem = std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return error.SyscallFailed;
        errdefer std.posix.munmap(mem);
        try ok(hvf.hv_vm_map(
            mem.ptr,
            guest_phys,
            size,
            hvf.HV_MEMORY_READ | hvf.HV_MEMORY_WRITE | hvf.HV_MEMORY_EXEC,
        ), "hv_vm_map");
        return mem;
    }

    pub fn unmapMemory(self: *Vm, host: []u8) void {
        _ = self;
        std.posix.munmap(@alignCast(host));
    }

    /// Create the framework GICv3 (before any vCPU), placing the distributor and
    /// redistributor at the memmap_arm bases, and record the region sizes the
    /// framework chose so the DTB can describe them accurately.
    pub fn setupIrq(self: *Vm) Error!void {
        const cfg = hvf.hv_gic_config_create();
        if (cfg == null) return error.SyscallFailed;
        try ok(hvf.hv_gic_config_set_distributor_base(cfg, arm.gicd_base), "gic distributor base");
        try ok(hvf.hv_gic_config_set_redistributor_base(cfg, arm.gicr_base), "gic redistributor base");
        // MSI region: the GIC isn't fully provisioned (and the redistributor base
        // query fails) without it. Reserve the top of the SPI range for MSI.
        try ok(hvf.hv_gic_config_set_msi_region_base(cfg, arm.msi_base), "gic msi base");
        var spi_base: u32 = 0;
        var spi_count: u32 = 0;
        _ = hvf.hv_gic_get_spi_interrupt_range(&spi_base, &spi_count);
        // Reserve the top of the SPI range for MSI, but never past the GICv2m
        // limit: the Linux gic-v2m driver rejects a frame whose (base + count)
        // exceeds V2M_MAX_SPI = 1019 (so the last usable SPI is 1018). The
        // framework reports an exclusive top of 1020, which trips that by one.
        const V2M_MAX_SPI: u32 = 1019;
        var top = spi_base + spi_count; // exclusive
        if (top > V2M_MAX_SPI) top = V2M_MAX_SPI;
        const msi_count: u32 = if (top - spi_base > 64) 64 else top - spi_base;
        const msi_base = top - msi_count;
        try ok(hvf.hv_gic_config_set_msi_interrupt_range(cfg, msi_base, msi_count), "gic msi range");
        self.msi_spi_base = msi_base;
        self.msi_spi_count = msi_count;
        try ok(hvf.hv_gic_create(cfg), "hv_gic_create");

        var ds: usize = arm.gicd_size;
        var rs: usize = arm.gicr_size;
        _ = hvf.hv_gic_get_distributor_size(&ds);
        _ = hvf.hv_gic_get_redistributor_region_size(&rs); // whole region, for the DTB
        self.gicd_size = ds;
        self.gicr_size = rs;
    }

    pub fn createVcpu(self: *Vm, id: u32) Error!Vcpu {
        _ = self;
        var handle: hvf.hv_vcpu_t = 0;
        var exit: *hvf.Exit = undefined;
        try ok(hvf.hv_vcpu_create(&handle, &exit, null), "hv_vcpu_create");
        // GICv3 affinity routing: MPIDR_EL1 must be set (bit 31 RES1; Aff0 = id)
        // before the GIC redistributor can be associated with this vCPU.
        _ = hvf.hv_vcpu_set_sys_reg(handle, hvf.HV_SYS_REG_MPIDR_EL1, 0x8000_0000 | @as(u64, id));
        return .{ .handle = handle, .exit = exit, .id = id };
    }
};

/// A full vCPU register context for snapshot/restore: GP regs, PC/SP/PSTATE, the
/// SIMD&FP file, and the EL1 system registers in hvf.SNAPSHOT_SYS_REGS order.
pub const CpuState = struct {
    x: [31]u64 = [_]u64{0} ** 31, // X0..X30
    pc: u64 = 0,
    cpsr: u64 = 0,
    fpcr: u64 = 0,
    fpsr: u64 = 0,
    v: [32]hvf.hv_simd_fp_uchar16 = [_]hvf.hv_simd_fp_uchar16{@splat(0)} ** 32,
    sys: [hvf.SNAPSHOT_SYS_REGS.len]u64 = [_]u64{0} ** hvf.SNAPSHOT_SYS_REGS.len,
    icc: [hvf.SNAPSHOT_ICC_REGS.len]u64 = [_]u64{0} ** hvf.SNAPSHOT_ICC_REGS.len,
};

/// Snapshot/restore coordination across vCPU threads. The orchestrator sets a
/// phase and forces every vCPU out of `hv_vcpu_run`; each vCPU self-captures or
/// self-restores its own context (register access is owning-thread only), parks,
/// and waits for the orchestrator to advance the phase.
pub const MAX_SNAP_CPUS = 8;
pub const SnapPhase = enum(u8) { running, quiesce, restoring, resumed };
pub const SnapCtl = struct {
    phase: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(SnapPhase.running)),
    parked: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    cpu: [MAX_SNAP_CPUS]CpuState = [_]CpuState{.{}} ** MAX_SNAP_CPUS,
};

/// Serialize the live GIC state into `buf`, returning its length (0 on failure).
/// `buf` must be large enough (the framework's state is a few KiB).
pub fn gicCaptureState(buf: []u8) usize {
    const st = hvf.hv_gic_state_create() orelse return 0;
    var size: usize = 0;
    if (hvf.hv_gic_state_get_size(st, &size) != hvf.HV_SUCCESS or size > buf.len) return 0;
    if (hvf.hv_gic_state_get_data(st, buf.ptr) != hvf.HV_SUCCESS) return 0;
    return size;
}

/// Restore GIC state from a buffer captured by gicCaptureState.
pub fn gicRestoreState(data: []const u8) bool {
    return hvf.hv_gic_set_state(data.ptr, data.len) == hvf.HV_SUCCESS;
}

pub const Vcpu = struct {
    handle: hvf.hv_vcpu_t,
    exit: *hvf.Exit,
    id: u32 = 0,

    pub fn deinit(self: *Vcpu) void {
        _ = hvf.hv_vcpu_destroy(self.handle);
    }

    /// Read this vCPU's full register context (owning thread only).
    pub fn capture(self: *Vcpu) CpuState {
        var s = CpuState{};
        for (&s.x, 0..) |*r, i| _ = hvf.hv_vcpu_get_reg(self.handle, hvf.HV_REG_X0 + @as(hvf.hv_reg_t, @intCast(i)), r);
        _ = hvf.hv_vcpu_get_reg(self.handle, hvf.HV_REG_PC, &s.pc);
        _ = hvf.hv_vcpu_get_reg(self.handle, hvf.HV_REG_CPSR, &s.cpsr);
        _ = hvf.hv_vcpu_get_reg(self.handle, hvf.HV_REG_FPCR, &s.fpcr);
        _ = hvf.hv_vcpu_get_reg(self.handle, hvf.HV_REG_FPSR, &s.fpsr);
        for (&s.v, 0..) |*q, i| _ = hvf.hv_vcpu_get_simd_fp_reg(self.handle, @intCast(i), q);
        for (hvf.SNAPSHOT_SYS_REGS, 0..) |reg, i| _ = hvf.hv_vcpu_get_sys_reg(self.handle, reg, &s.sys[i]);
        for (hvf.SNAPSHOT_ICC_REGS, 0..) |reg, i| _ = hvf.hv_gic_get_icc_reg(self.handle, reg, &s.icc[i]);
        return s;
    }

    /// Write a register context back into this vCPU (owning thread only).
    pub fn restore(self: *Vcpu, s: *const CpuState) void {
        for (s.x, 0..) |r, i| _ = hvf.hv_vcpu_set_reg(self.handle, hvf.HV_REG_X0 + @as(hvf.hv_reg_t, @intCast(i)), r);
        _ = hvf.hv_vcpu_set_reg(self.handle, hvf.HV_REG_PC, s.pc);
        _ = hvf.hv_vcpu_set_reg(self.handle, hvf.HV_REG_CPSR, s.cpsr);
        _ = hvf.hv_vcpu_set_reg(self.handle, hvf.HV_REG_FPCR, s.fpcr);
        _ = hvf.hv_vcpu_set_reg(self.handle, hvf.HV_REG_FPSR, s.fpsr);
        for (s.v, 0..) |q, i| _ = hvf.hv_vcpu_set_simd_fp_reg(self.handle, @intCast(i), q);
        for (hvf.SNAPSHOT_SYS_REGS, 0..) |reg, i| _ = hvf.hv_vcpu_set_sys_reg(self.handle, reg, s.sys[i]);
        for (hvf.SNAPSHOT_ICC_REGS, 0..) |reg, i| _ = hvf.hv_gic_set_icc_reg(self.handle, reg, s.icc[i]);
    }

    /// The guest-physical base the framework placed this vCPU's GIC redistributor
    /// at (valid after creation). The DTB must describe this address.
    pub fn redistributorBase(self: *Vcpu) u64 {
        var base: hvf.hv_ipa_t = 0;
        _ = hvf.hv_gic_get_redistributor_base(self.handle, &base);
        return base;
    }

    /// aarch64 boot entry: PC = kernel base, X0 = DTB pointer (the Linux arm64
    /// boot protocol), PSTATE = EL1h with interrupts masked.
    pub fn setAarch64Entry(self: *Vcpu, pc: u64, dtb: u64) Error!void {
        try ok(hvf.hv_vcpu_set_reg(self.handle, hvf.HV_REG_CPSR, CPSR_EL1H_MASKED), "set CPSR");
        try ok(hvf.hv_vcpu_set_reg(self.handle, hvf.HV_REG_X0, dtb), "set X0");
        try ok(hvf.hv_vcpu_set_reg(self.handle, hvf.HV_REG_PC, pc), "set PC");
    }

    pub fn run(self: *Vcpu, bus: *io.Bus, power: *pwr.Power) !StopReason {
        return self.runSmp(bus, power, null, null);
    }

    /// Run loop with optional SMP control (PSCI CPU_ON routing) and optional
    /// snapshot control (quiesce + self-capture/restore). The single-CPU `run` is
    /// this with both null.
    pub fn runSmp(self: *Vcpu, bus: *io.Bus, power: *pwr.Power, sc: ?*smp.Smp, snap: ?*SnapCtl) !StopReason {
        while (true) {
            try ok(hvf.hv_vcpu_run(self.handle), "hv_vcpu_run");
            // Snapshot rendezvous: if the orchestrator has requested a quiesce,
            // self-capture or self-restore this vCPU's context (register access is
            // owning-thread only), park, and wait for the phase to advance. Checked
            // before handling the exit so a forced-exit (hv_vcpus_exit) parks here.
            if (snap) |sn| {
                const ph: SnapPhase = @enumFromInt(sn.phase.load(.acquire));
                if (ph == .quiesce or ph == .restoring) {
                    if (ph == .quiesce) sn.cpu[self.id] = self.capture() else self.restore(&sn.cpu[self.id]);
                    _ = sn.parked.fetchAdd(1, .release);
                    while (@as(SnapPhase, @enumFromInt(sn.phase.load(.acquire))) != .resumed) std.atomic.spinLoopHint();
                    continue; // re-enter the guest with (possibly restored) state
                }
            }
            switch (self.exit.reason) {
                hvf.HV_EXIT_REASON_EXCEPTION => {
                    const esr = self.exit.exception.syndrome;
                    const ec = (esr >> 26) & 0x3f;
                    switch (ec) {
                        EC_DATA_ABORT_LOWER => self.handleDataAbort(bus, esr),
                        EC_HVC => self.handlePsci(power, sc),
                        EC_WFX => self.stepPc(4), // idle wait; the GIC wakes us
                        EC_SYSREG => self.handleSysReg(esr),
                        else => {
                            std.debug.print("[nether] unhandled exception EC=0x{x} ESR=0x{x}\n", .{ ec, esr });
                            return error.UnhandledExit;
                        },
                    }
                },
                hvf.HV_EXIT_REASON_VTIMER_ACTIVATED => {}, // no timer model yet; resume
                hvf.HV_EXIT_REASON_CANCELED => {}, // spurious wake; resume
                else => {
                    std.debug.print("[nether] unexpected exit reason {d}\n", .{self.exit.reason});
                    return error.UnhandledExit;
                },
            }
            if (power.action) |a| return switch (a) {
                .reset => .reset,
                .shutdown => .shutdown,
            };
        }
    }

    /// Decode an ISS-valid data abort into an MMIO access on the bus, then step
    /// past the faulting instruction. ESR fields: ISV[24], SAS[23:22] (size),
    /// SRT[20:16] (transfer reg, 31 = XZR), WnR[6] (write), IL[25] (instr len).
    fn handleDataAbort(self: *Vcpu, bus: *io.Bus, esr: u64) void {
        const ipa = self.exit.exception.physical_address;
        const isv = (esr >> 24) & 1;
        if (isv == 1) {
            const sas: u3 = @truncate((esr >> 22) & 3);
            const srt: u5 = @truncate((esr >> 16) & 0x1f);
            const wnr = (esr >> 6) & 1;
            const n: usize = @as(usize, 1) << sas;
            var buf: [8]u8 = undefined;
            if (wnr == 1) {
                const val = self.getX(srt);
                writeLE(buf[0..n], val);
                bus.mmioWrite(ipa, buf[0..n]);
            } else {
                bus.mmioRead(ipa, buf[0..n]);
                self.setX(srt, readLE(buf[0..n]));
            }
        }
        // Step over the (4-byte for IL=1, else 2-byte) faulting instruction.
        self.stepPc(if ((esr >> 25) & 1 == 1) 4 else 2);
    }

    /// PSCI over HVC: the guest's power firmware. Unlike a data abort, HV_REG_PC
    /// on an HVC exit already points past the `hvc` (ELR semantics), so we must
    /// NOT step it - the result just goes in x0.
    fn handlePsci(self: *Vcpu, power: *pwr.Power, sc: ?*smp.Smp) void {
        const fid = self.getX(0) & 0xffff_ffff;
        switch (fid) {
            PSCI_VERSION => self.setX(0, PSCI_VERSION_1_0),
            PSCI_SYSTEM_OFF => power.request(.shutdown),
            PSCI_SYSTEM_RESET => power.request(.reset),
            PSCI_CPU_ON_32, PSCI_CPU_ON_64 => {
                // CPU_ON(target_mpidr, entry_point, context_id): wake the parked
                // secondary so it begins executing the kernel's secondary entry.
                const r: i64 = if (sc) |s| s.cpuOn(self.getX(1), self.getX(2), self.getX(3)) else smp.PSCI_NOT_SUPPORTED;
                self.setX(0, @bitCast(r));
            },
            PSCI_AFFINITY_INFO_32, PSCI_AFFINITY_INFO_64 => {
                const r: i64 = if (sc) |s| s.affinityInfo(self.getX(1)) else smp.AFFINITY_OFF;
                self.setX(0, @bitCast(r));
            },
            PSCI_FEATURES => {
                // Advertise the calls we implement (0 = present) so the guest uses
                // PSCI for SMP bringup; everything else is unsupported.
                const q = self.getX(1) & 0xffff_ffff;
                const supported = q == PSCI_CPU_ON_32 or q == PSCI_CPU_ON_64 or
                    q == PSCI_AFFINITY_INFO_32 or q == PSCI_AFFINITY_INFO_64 or
                    q == PSCI_VERSION or q == PSCI_SYSTEM_OFF or q == PSCI_SYSTEM_RESET;
                self.setX(0, if (supported) 0 else PSCI_NOT_SUPPORTED);
            },
            else => self.setX(0, PSCI_NOT_SUPPORTED),
        }
    }

    /// Trapped system-register access (EC 0x18): emulate as RAZ/WI - reads return
    /// 0, writes are dropped. ISS[0]=direction (1=read/MRS), ISS[9:5]=Rt. Fine for
    /// the debug/PMU/implementation-defined registers the kernel probes at boot.
    fn handleSysReg(self: *Vcpu, esr: u64) void {
        const iss = esr & 0x1ff_ffff;
        if (iss & 1 == 1) self.setX(@truncate((iss >> 5) & 0x1f), 0); // MRS -> RAZ
        self.stepPc(4);
    }

    fn stepPc(self: *Vcpu, bytes: u64) void {
        var pc: u64 = 0;
        _ = hvf.hv_vcpu_get_reg(self.handle, hvf.HV_REG_PC, &pc);
        _ = hvf.hv_vcpu_set_reg(self.handle, hvf.HV_REG_PC, pc +% bytes);
    }

    fn getX(self: *Vcpu, reg: u5) u64 {
        if (reg == 31) return 0; // XZR reads as zero
        var v: u64 = 0;
        _ = hvf.hv_vcpu_get_reg(self.handle, hvf.HV_REG_X0 + @as(hvf.hv_reg_t, reg), &v);
        return v;
    }

    fn setX(self: *Vcpu, reg: u5, value: u64) void {
        if (reg == 31) return; // writes to XZR are discarded
        _ = hvf.hv_vcpu_set_reg(self.handle, hvf.HV_REG_X0 + @as(hvf.hv_reg_t, reg), value);
    }

    // --- x86 boot-entry stubs (never reached on HVF; keep PVH compiling) -----

    pub fn setRealModeEntry(self: *Vcpu, ip: u64) Error!void {
        _ = self;
        _ = ip;
        return error.Unimplemented;
    }

    pub fn setProtectedMode(self: *Vcpu, eip: u64, ebx: u64, gdt_base: u64) Error!void {
        _ = self;
        _ = eip;
        _ = ebx;
        _ = gdt_base;
        return error.Unimplemented;
    }
};

/// Little-endian marshalling up to 8 bytes (MMIO data is up to a doubleword).
fn writeLE(bytes: []u8, value: u64) void {
    for (bytes, 0..) |*b, i| b.* = @truncate(value >> @intCast(i * 8));
}

fn readLE(bytes: []const u8) u64 {
    var v: u64 = 0;
    for (bytes, 0..) |b, i| v |= @as(u64, b) << @intCast(i * 8);
    return v;
}
