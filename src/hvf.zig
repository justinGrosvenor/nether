//! Hand-rolled bindings for Apple's Hypervisor.framework (arm64), matching the
//! hand-rolled-KVM-ABI choice in decisions D7: no @cImport, no libc headers,
//! just the extern declarations and constants we use. Linked via -framework
//! Hypervisor (build.zig, macOS only). Only compiled on macOS (the HVF backend
//! is comptime-selected there; see backend.zig).
//!
//! Reference: <Hypervisor/hv.h>, <Hypervisor/hv_vcpu.h>, <Hypervisor/hv_vcpu_types.h>.

pub const hv_return_t = c_int;
pub const HV_SUCCESS: hv_return_t = 0;

pub const hv_vcpu_t = u64;
pub const hv_ipa_t = u64;

/// hv_memory_flags_t bits for hv_vm_map.
pub const HV_MEMORY_READ: u64 = 1 << 0;
pub const HV_MEMORY_WRITE: u64 = 1 << 1;
pub const HV_MEMORY_EXEC: u64 = 1 << 2;

/// hv_reg_t: general-purpose and special registers. X0..X30 are 0..30; note the
/// data-abort register field (SRT) value 31 means XZR, NOT PC, so callers must
/// special-case 31 rather than indexing HV_REG_X0 + 31 (which collides with PC).
pub const hv_reg_t = c_int;
pub const HV_REG_X0: hv_reg_t = 0;
pub const HV_REG_PC: hv_reg_t = 31;
pub const HV_REG_FPCR: hv_reg_t = 32;
pub const HV_REG_FPSR: hv_reg_t = 33;
pub const HV_REG_CPSR: hv_reg_t = 34;

/// hv_exit_reason_t.
pub const HV_EXIT_REASON_CANCELED: u32 = 0;
pub const HV_EXIT_REASON_EXCEPTION: u32 = 1;
pub const HV_EXIT_REASON_VTIMER_ACTIVATED: u32 = 2;
pub const HV_EXIT_REASON_UNKNOWN: u32 = 3;

/// hv_vcpu_exit_exception_t: the syndrome (ESR_EL2) plus fault addresses.
pub const ExitException = extern struct {
    syndrome: u64,
    virtual_address: u64,
    physical_address: hv_ipa_t,
};

/// hv_vcpu_exit_t: reason (u32, 4 bytes padding before the 8-aligned exception).
pub const Exit = extern struct {
    reason: u32,
    exception: ExitException,
};

pub extern fn hv_vm_create(config: ?*anyopaque) hv_return_t;
pub extern fn hv_vm_destroy() hv_return_t;
pub extern fn hv_vm_map(addr: *anyopaque, ipa: hv_ipa_t, size: usize, flags: u64) hv_return_t;
pub extern fn hv_vm_unmap(ipa: hv_ipa_t, size: usize) hv_return_t;

pub extern fn hv_vcpu_create(vcpu: *hv_vcpu_t, exit: **Exit, config: ?*anyopaque) hv_return_t;
pub extern fn hv_vcpu_destroy(vcpu: hv_vcpu_t) hv_return_t;
pub extern fn hv_vcpu_run(vcpu: hv_vcpu_t) hv_return_t;
pub extern fn hv_vcpu_set_reg(vcpu: hv_vcpu_t, reg: hv_reg_t, value: u64) hv_return_t;
pub extern fn hv_vcpu_get_reg(vcpu: hv_vcpu_t, reg: hv_reg_t, value: *u64) hv_return_t;
/// Force the listed vCPUs out of `hv_vcpu_run` (used to quiesce secondaries for a
/// consistent snapshot). Callable from any thread, unlike run/get_reg/set_reg
/// which must run on the vCPU's owning thread.
pub extern fn hv_vcpus_exit(vcpus: [*]const hv_vcpu_t, count: u32) hv_return_t;

/// SIMD&FP registers (V0..V31), each a 128-bit value. FPCR/FPSR are the plain
/// HV_REG_FPCR/FPSR above. Needed for a complete vCPU snapshot.
pub const hv_simd_fp_uchar16 = @Vector(16, u8);
pub const hv_simd_fp_reg_t = c_int;
pub extern fn hv_vcpu_get_simd_fp_reg(vcpu: hv_vcpu_t, reg: hv_simd_fp_reg_t, value: *hv_simd_fp_uchar16) hv_return_t;
pub extern fn hv_vcpu_set_simd_fp_reg(vcpu: hv_vcpu_t, reg: hv_simd_fp_reg_t, value: hv_simd_fp_uchar16) hv_return_t;

/// System registers (hv_sys_reg_t). MPIDR_EL1 holds the vCPU's GICv3 affinity and
/// must be set before the GIC redistributor can be associated with the vCPU.
pub const hv_sys_reg_t = c_int;
pub const HV_SYS_REG_MPIDR_EL1: hv_sys_reg_t = 0xc005;
pub extern fn hv_vcpu_set_sys_reg(vcpu: hv_vcpu_t, reg: hv_sys_reg_t, value: u64) hv_return_t;
pub extern fn hv_vcpu_get_sys_reg(vcpu: hv_vcpu_t, reg: hv_sys_reg_t, value: *u64) hv_return_t;

/// The EL1 execution-context system registers captured/restored by a snapshot
/// (values from <Hypervisor/hv_vcpu_types.h>). This covers the MMU (SCTLR, TTBR0/1,
/// TCR, MAIR/AMAIR), exception state (SPSR/ELR/ESR/FAR/VBAR), stacks (SP_EL0/1),
/// thread pointers, the cache-select, pointer-auth key, and the virtual timer
/// (CNTV_CTL/CVAL/KCTL + CNTVOFF, which rebases the guest's view of the counter so
/// time is continuous across restore). MPIDR is set at vCPU creation, not here.
pub const SNAPSHOT_SYS_REGS = [_]hv_sys_reg_t{
    0xc080, // SCTLR_EL1
    0xc082, // CPACR_EL1
    0xc100, // TTBR0_EL1
    0xc101, // TTBR1_EL1
    0xc102, // TCR_EL1
    0xc200, // SPSR_EL1
    0xc201, // ELR_EL1
    0xc208, // SP_EL0
    0xe208, // SP_EL1
    0xc288, // AFSR0_EL1
    0xc289, // AFSR1_EL1
    0xc290, // ESR_EL1
    0xc300, // FAR_EL1
    0xc3a0, // PAR_EL1
    0xc510, // MAIR_EL1
    0xc518, // AMAIR_EL1
    0xc600, // VBAR_EL1
    0xc681, // CONTEXTIDR_EL1
    0xc684, // TPIDR_EL1
    0xde82, // TPIDR_EL0
    0xde83, // TPIDRRO_EL0
    0xd000, // CSSELR_EL1
    0x8012, // MDSCR_EL1
    0xc708, // CNTKCTL_EL1
    0xdf19, // CNTV_CTL_EL0
    0xdf1a, // CNTV_CVAL_EL0
    0xe703, // CNTVOFF_EL2
    // Pointer-authentication keys: the kernel signs return addresses with these,
    // so a restore onto a fresh vCPU (whose keys differ) would fault on the first
    // AUTIASP unless they travel with the snapshot. All five pairs (A/B
    // instruction, A/B data, generic).
    0xc108, // APIAKEYLO_EL1
    0xc109, // APIAKEYHI_EL1
    0xc10a, // APIBKEYLO_EL1
    0xc10b, // APIBKEYHI_EL1
    0xc110, // APDAKEYLO_EL1
    0xc111, // APDAKEYHI_EL1
    0xc112, // APDBKEYLO_EL1
    0xc113, // APDBKEYHI_EL1
    0xc118, // APGAKEYLO_EL1
    0xc119, // APGAKEYHI_EL1
};

/// GIC state save/restore (macOS 15+): `state_create` snapshots the live GIC into
/// an opaque object, `get_size`/`get_data` serialize it to a byte buffer, and
/// `set_state` restores from such a buffer. The single hardest piece of a VM
/// snapshot to get right; Apple provides it directly so we need not model an ITS.
pub const hv_gic_state_t = ?*anyopaque;
pub extern fn hv_gic_state_create() hv_gic_state_t;
pub extern fn hv_gic_state_get_size(state: hv_gic_state_t, size: *usize) hv_return_t;
pub extern fn hv_gic_state_get_data(state: hv_gic_state_t, data: *anyopaque) hv_return_t;
pub extern fn hv_gic_set_state(data: *const anyopaque, size: usize) hv_return_t;

/// GICv3 CPU-interface (ICC_*) registers: per-vCPU state that hv_gic_state does
/// NOT cover (that snapshots the distributor + redistributors). Without restoring
/// these onto a fresh vCPU, the CPU interface stays at reset (group 1 disabled,
/// priority mask blocking everything) and the core rejects every interrupt -
/// including the timer - so a restored guest is alive but frozen. SRE must be set
/// first (it gates sysreg access to the interface), so it leads the list.
pub const hv_gic_icc_reg_t = c_int;
pub extern fn hv_gic_get_icc_reg(vcpu: hv_vcpu_t, reg: hv_gic_icc_reg_t, value: *u64) hv_return_t;
pub extern fn hv_gic_set_icc_reg(vcpu: hv_vcpu_t, reg: hv_gic_icc_reg_t, value: u64) hv_return_t;
pub const SNAPSHOT_ICC_REGS = [_]hv_gic_icc_reg_t{
    0xc665, // SRE_EL1 (first: enables sysreg access to the interface)
    0xc230, // PMR_EL1 (priority mask)
    0xc666, // IGRPEN0_EL1
    0xc667, // IGRPEN1_EL1 (group 1 enable)
    0xc643, // BPR0_EL1
    0xc663, // BPR1_EL1
    0xc664, // CTLR_EL1
    0xc644, // AP0R0_EL1
    0xc648, // AP1R0_EL1
};

/// Framework GIC (macOS 15+): an in-hypervisor GICv3, the aarch64 analog of the
/// in-kernel LAPIC the KVM split irqchip gives us. Created once per VM, before
/// vCPUs. The distributor/redistributor MMIO is serviced by the framework (not
/// surfaced to us as data aborts); we raise device interrupts with set_spi.
pub const hv_gic_config_t = ?*anyopaque;
pub extern fn hv_gic_config_create() hv_gic_config_t;
pub extern fn hv_gic_config_set_distributor_base(config: hv_gic_config_t, base: hv_ipa_t) hv_return_t;
pub extern fn hv_gic_config_set_redistributor_base(config: hv_gic_config_t, base: hv_ipa_t) hv_return_t;
pub extern fn hv_gic_config_set_msi_region_base(config: hv_gic_config_t, base: hv_ipa_t) hv_return_t;
pub extern fn hv_gic_config_set_msi_interrupt_range(config: hv_gic_config_t, msi_intid_base: u32, msi_intid_count: u32) hv_return_t;
pub extern fn hv_gic_create(config: hv_gic_config_t) hv_return_t;
pub extern fn hv_gic_get_msi_region_size(size: *usize) hv_return_t;
pub extern fn hv_gic_get_spi_interrupt_range(spi_intid_base: *u32, spi_intid_count: *u32) hv_return_t;
pub extern fn hv_gic_get_distributor_size(size: *usize) hv_return_t;
pub extern fn hv_gic_get_redistributor_size(size: *usize) hv_return_t;
pub extern fn hv_gic_get_redistributor_region_size(size: *usize) hv_return_t;
/// The framework decides where each vCPU's redistributor lands; query it (after
/// the vCPU exists) and describe that address in the DTB.
pub extern fn hv_gic_get_redistributor_base(vcpu: hv_vcpu_t, base: *hv_ipa_t) hv_return_t;
pub extern fn hv_gic_get_distributor_base_alignment(alignment: *usize) hv_return_t;
pub extern fn hv_gic_get_redistributor_base_alignment(alignment: *usize) hv_return_t;
pub extern fn hv_gic_set_spi(intid: u32, level: bool) hv_return_t;
/// Deliver a message-signalled interrupt: `address` is the MSI doorbell the guest
/// programmed into the device's MSI-X message (must fall in the configured MSI
/// region), `intid` is the GIC interrupt id to raise (must fall in the configured
/// MSI interrupt range). The VMM calls this in place of the device writing the
/// doorbell, so the guest sees a normal GIC MSI without us modelling an ITS.
pub extern fn hv_gic_send_msi(address: hv_ipa_t, intid: u32) hv_return_t;

/// libkern cache maintenance: after writing guest code through the host mapping,
/// invalidate the instruction cache so the guest core fetches what we wrote
/// (host data writes are not I-cache coherent on Apple Silicon).
pub extern fn sys_icache_invalidate(start: *anyopaque, len: usize) void;
