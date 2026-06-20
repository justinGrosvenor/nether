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

/// System registers (hv_sys_reg_t). MPIDR_EL1 holds the vCPU's GICv3 affinity and
/// must be set before the GIC redistributor can be associated with the vCPU.
pub const hv_sys_reg_t = c_int;
pub const HV_SYS_REG_MPIDR_EL1: hv_sys_reg_t = 0xc005;
pub extern fn hv_vcpu_set_sys_reg(vcpu: hv_vcpu_t, reg: hv_sys_reg_t, value: u64) hv_return_t;
pub extern fn hv_vcpu_get_sys_reg(vcpu: hv_vcpu_t, reg: hv_sys_reg_t, value: *u64) hv_return_t;

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

/// libkern cache maintenance: after writing guest code through the host mapping,
/// invalidate the instruction cache so the guest core fetches what we wrote
/// (host data writes are not I-cache coherent on Apple Silicon).
pub extern fn sys_icache_invalidate(start: *anyopaque, len: usize) void;
