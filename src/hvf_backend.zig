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

const StopReason = hvtypes.StopReason;
const Error = hvtypes.Error;

/// ESR_EL2 exception classes we care about.
const EC_DATA_ABORT_LOWER: u64 = 0x24;
const EC_HVC: u64 = 0x16; // HVC instruction from AArch64 (PSCI firmware calls)
const EC_WFX: u64 = 0x01; // trapped WFI/WFE (idle); resume past it

/// PSCI function IDs (the guest's "firmware" for power; the arm64 analog of the
/// ACPI PM block). The guest calls these via `hvc #0` with the FID in w0/x0.
const PSCI_VERSION: u64 = 0x8400_0000;
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
    gicr_size: u64 = arm.gicr_size,

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
        try ok(hvf.hv_gic_create(cfg), "hv_gic_create");

        var ds: usize = arm.gicd_size;
        var rs: usize = arm.gicr_size;
        _ = hvf.hv_gic_get_distributor_size(&ds);
        _ = hvf.hv_gic_get_redistributor_size(&rs);
        self.gicd_size = ds;
        self.gicr_size = rs;
    }

    pub fn createVcpu(self: *Vm, id: u32) Error!Vcpu {
        _ = self;
        _ = id;
        var handle: hvf.hv_vcpu_t = 0;
        var exit: *hvf.Exit = undefined;
        try ok(hvf.hv_vcpu_create(&handle, &exit, null), "hv_vcpu_create");
        return .{ .handle = handle, .exit = exit };
    }
};

pub const Vcpu = struct {
    handle: hvf.hv_vcpu_t,
    exit: *hvf.Exit,

    pub fn deinit(self: *Vcpu) void {
        _ = hvf.hv_vcpu_destroy(self.handle);
    }

    /// aarch64 boot entry: PC = kernel base, X0 = DTB pointer (the Linux arm64
    /// boot protocol), PSTATE = EL1h with interrupts masked.
    pub fn setAarch64Entry(self: *Vcpu, pc: u64, dtb: u64) Error!void {
        try ok(hvf.hv_vcpu_set_reg(self.handle, hvf.HV_REG_CPSR, CPSR_EL1H_MASKED), "set CPSR");
        try ok(hvf.hv_vcpu_set_reg(self.handle, hvf.HV_REG_X0, dtb), "set X0");
        try ok(hvf.hv_vcpu_set_reg(self.handle, hvf.HV_REG_PC, pc), "set PC");
    }

    pub fn run(self: *Vcpu, bus: *io.Bus, power: *pwr.Power) !StopReason {
        while (true) {
            try ok(hvf.hv_vcpu_run(self.handle), "hv_vcpu_run");
            switch (self.exit.reason) {
                hvf.HV_EXIT_REASON_EXCEPTION => {
                    const esr = self.exit.exception.syndrome;
                    const ec = (esr >> 26) & 0x3f;
                    switch (ec) {
                        EC_DATA_ABORT_LOWER => self.handleDataAbort(bus, esr),
                        EC_HVC => self.handlePsci(power),
                        EC_WFX => self.stepPc(4), // idle wait; the GIC wakes us
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
    fn handlePsci(self: *Vcpu, power: *pwr.Power) void {
        const fid = self.getX(0) & 0xffff_ffff;
        switch (fid) {
            PSCI_VERSION => self.setX(0, PSCI_VERSION_1_0),
            PSCI_SYSTEM_OFF => power.request(.shutdown),
            PSCI_SYSTEM_RESET => power.request(.reset),
            else => self.setX(0, PSCI_NOT_SUPPORTED),
        }
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
