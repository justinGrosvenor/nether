//! Minimal KVM ABI for Phase 0.
//!
//! Hand-rolled `extern struct` layouts and comptime-derived ioctl numbers for
//! exactly the surface the skeleton needs: create VM/vCPU, register one memory
//! region, set real-mode entry state, and run. This deliberately avoids
//! `@cImport("linux/kvm.h")` for now; see docs/decisions.md (D7): cImport pulls
//! kernel uapi headers that aren't present when cross-compiling from a non-Linux
//! host, which would break `zig build` on macOS. The layouts below match the
//! kernel's and are checked against KVM's published ioctl numbers in a test.

const std = @import("std");
const linux = std.os.linux;

// --- ioctl number construction (asm-generic) -------------------------------

const KVMIO: u32 = 0xAE;

const IOC_NONE: u32 = 0;
const IOC_WRITE: u32 = 1;
const IOC_READ: u32 = 2;

fn ioc(dir: u32, nr: u32, size: u32) u32 {
    return (dir << 30) | (size << 16) | (KVMIO << 8) | nr;
}
fn io(nr: u32) u32 {
    return ioc(IOC_NONE, nr, 0);
}
fn ior(nr: u32, comptime T: type) u32 {
    return ioc(IOC_READ, nr, @sizeOf(T));
}
fn iow(nr: u32, comptime T: type) u32 {
    return ioc(IOC_WRITE, nr, @sizeOf(T));
}

pub const GET_API_VERSION = io(0x00);
pub const CREATE_VM = io(0x01);
pub const GET_VCPU_MMAP_SIZE = io(0x04);
pub const CREATE_VCPU = io(0x41);
pub const RUN = io(0x80);
pub const SET_USER_MEMORY_REGION = iow(0x46, UserspaceMemoryRegion);
pub const GET_REGS = ior(0x81, Regs);
pub const SET_REGS = iow(0x82, Regs);
pub const GET_SREGS = ior(0x83, Sregs);
pub const SET_SREGS = iow(0x84, Sregs);
pub const GET_MP_STATE = ior(0x98, MpState);
pub const SET_MP_STATE = iow(0x99, MpState);

// --- snapshot: full vCPU + VM state capture/restore ------------------------
// The ioctls that enumerate every architectural register so a guest can be
// serialized and re-created in a fresh process (cross-process fork). kvm_msrs is
// variable-length like kvm_cpuid2, so its ioctl encodes only the 8-byte header.
pub const GET_MSRS = ioc(IOC_READ | IOC_WRITE, 0x88, 8);
pub const SET_MSRS = ioc(IOC_WRITE, 0x89, 8);
pub const GET_LAPIC = ior(0x8e, LapicState);
pub const SET_LAPIC = iow(0x8f, LapicState);
pub const GET_VCPU_EVENTS = ior(0x9f, VcpuEvents);
pub const SET_VCPU_EVENTS = iow(0xa0, VcpuEvents);
pub const GET_DEBUGREGS = ior(0xa1, Debugregs);
pub const SET_DEBUGREGS = iow(0xa2, Debugregs);
pub const GET_XSAVE = ior(0xa4, Xsave);
pub const SET_XSAVE = iow(0xa5, Xsave);
pub const GET_XCRS = ior(0xa6, Xcrs);
pub const SET_XCRS = iow(0xa7, Xcrs);
// VM-level (fd = vm_fd): the paravirt clock, for TSC/kvmclock continuity.
pub const GET_CLOCK = ior(0x7c, ClockData);
pub const SET_CLOCK = iow(0x7b, ClockData);

pub const CHECK_EXTENSION = io(0x03);
// kvm_cpuid2 is variable-length; the ioctl number encodes only the 8-byte header.
pub const GET_SUPPORTED_CPUID = ioc(IOC_READ | IOC_WRITE, 0x05, 8);
pub const SET_CPUID2 = ioc(IOC_WRITE, 0x90, 8);
pub const ENABLE_CAP = iow(0xa3, EnableCap);
pub const IRQFD = iow(0x76, Irqfd);
pub const IOEVENTFD = iow(0x79, Ioeventfd);
pub const SIGNAL_MSI = iow(0xa5, Msi);

pub const API_VERSION = 12;

// --- capabilities and interrupt flags --------------------------------------

pub const CAP_SPLIT_IRQCHIP = 121;

pub const IOEVENTFD_FLAG_DATAMATCH = 1 << 0;
pub const IOEVENTFD_FLAG_PIO = 1 << 1;
pub const IRQFD_FLAG_RESAMPLE = 1 << 1;

// --- vCPU run-state (mp_state) ---------------------------------------------
//
// With an in-kernel LAPIC, KVM defaults the BSP to RUNNABLE and every AP to
// UNINITIALIZED, so an AP parks inside KVM_RUN until the BSP's INIT then SIPI
// walks it UNINITIALIZED -> INIT_RECEIVED -> RUNNABLE. Reading mp_state back is
// the decisive SMP diagnostic: an AP still UNINITIALIZED/INIT_RECEIVED long
// after boot means the SIPI never reached it; RUNNABLE/HALTED means it started.
pub const MpState = extern struct { mp_state: u32 };

pub const MP_STATE_RUNNABLE = 0;
pub const MP_STATE_UNINITIALIZED = 1;
pub const MP_STATE_INIT_RECEIVED = 2;
pub const MP_STATE_HALTED = 3;
pub const MP_STATE_SIPI_RECEIVED = 4;

// --- exit reasons ----------------------------------------------------------

pub const EXIT_UNKNOWN = 0;
pub const EXIT_IO = 2;
pub const EXIT_HLT = 5;
pub const EXIT_MMIO = 6;
pub const EXIT_SHUTDOWN = 8;
pub const EXIT_FAIL_ENTRY = 9;
pub const EXIT_INTERNAL_ERROR = 17;

pub const EXIT_IO_IN = 0;
pub const EXIT_IO_OUT = 1;

pub const EXIT_IOAPIC_EOI = 26;

// --- structures (must match kernel layout) ---------------------------------

pub const UserspaceMemoryRegion = extern struct {
    slot: u32,
    flags: u32,
    guest_phys_addr: u64,
    memory_size: u64,
    userspace_addr: u64,
};

pub const Regs = extern struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rsp: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    rip: u64,
    rflags: u64,
};

pub const Segment = extern struct {
    base: u64,
    limit: u32,
    selector: u16,
    type_: u8,
    present: u8,
    dpl: u8,
    db: u8,
    s: u8,
    l: u8,
    g: u8,
    avl: u8,
    unusable: u8,
    padding: u8,
};

pub const Dtable = extern struct {
    base: u64,
    limit: u16,
    padding: [3]u16,
};

pub const Sregs = extern struct {
    cs: Segment,
    ds: Segment,
    es: Segment,
    fs: Segment,
    gs: Segment,
    ss: Segment,
    tr: Segment,
    ldt: Segment,
    gdt: Dtable,
    idt: Dtable,
    cr0: u64,
    cr2: u64,
    cr3: u64,
    cr4: u64,
    cr8: u64,
    efer: u64,
    apic_base: u64,
    interrupt_bitmap: [4]u64,
};

pub const RunIo = extern struct {
    direction: u8,
    size: u8,
    port: u16,
    count: u32,
    data_offset: u64,
};

pub const RunMmio = extern struct {
    phys_addr: u64,
    data: [8]u8,
    len: u32,
    is_write: u8,
};

/// The shared `kvm_run` communication page. Only the head and the exit-info
/// union members Phase 0 touches are modeled; the union is padded to the kernel
/// size so layout past it stays correct as more members are added.
pub const Run = extern struct {
    request_interrupt_window: u8,
    immediate_exit: u8,
    padding1: [6]u8,
    exit_reason: u32,
    ready_for_interrupt_injection: u8,
    if_flag: u8,
    flags: u16,
    cr8: u64,
    apic_base: u64,
    exit: extern union {
        io: RunIo,
        mmio: RunMmio,
        eoi: extern struct { vector: u8 }, // KVM_EXIT_IOAPIC_EOI
        padding: [256]u8,
    },
};

// --- interrupt / capability structures -------------------------------------

pub const EnableCap = extern struct {
    cap: u32,
    flags: u32,
    args: [4]u64,
    pad: [64]u8,
};

pub const Irqfd = extern struct {
    fd: u32,
    gsi: u32,
    flags: u32,
    resamplefd: u32,
    pad: [16]u8,
};

pub const Ioeventfd = extern struct {
    datamatch: u64,
    addr: u64,
    len: u32,
    fd: i32,
    flags: u32,
    pad: [36]u8,
};

pub const CpuidEntry = extern struct {
    function: u32,
    index: u32,
    flags: u32,
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
    padding: [3]u32 = .{ 0, 0, 0 },
};

/// kvm_cpuid2 with inline capacity. `nent` is set to the capacity before
/// GET_SUPPORTED_CPUID and to the populated count before SET_CPUID2.
pub const Cpuid2 = extern struct {
    nent: u32,
    padding: u32 = 0,
    entries: [128]CpuidEntry = undefined,
};

pub const Msi = extern struct {
    address_lo: u32,
    address_hi: u32,
    data: u32,
    flags: u32,
    devid: u32,
    pad: [12]u8,
};

// --- snapshot state structures (must match kernel layout) ------------------

pub const MsrEntry = extern struct { index: u32, reserved: u32 = 0, data: u64 = 0 };

/// kvm_msrs with inline capacity. `nmsrs` is the populated count; the kernel
/// reads/writes that many entries. GET returns how many it actually filled.
pub const Msrs = extern struct {
    nmsrs: u32,
    pad: u32 = 0,
    entries: [MSR_SAVE_LIST.len]MsrEntry = undefined,
};

/// MSRs saved/restored across a fork. The SYSCALL/SYSENTER path, segment bases,
/// PAT, the TSC, and the KVM paravirt-clock MSRs (system-time/wall-clock) are the
/// ones a Linux guest depends on; missing the clock MSRs corrupts guest time.
pub const MSR_SAVE_LIST = [_]u32{
    0x00000010, // IA32_TSC
    0x0000001b, // IA32_APIC_BASE
    0x00000174, // IA32_SYSENTER_CS
    0x00000175, // IA32_SYSENTER_ESP
    0x00000176, // IA32_SYSENTER_EIP
    0x00000277, // IA32_CR_PAT
    0xc0000080, // EFER
    0xc0000081, // STAR
    0xc0000082, // LSTAR
    0xc0000083, // CSTAR
    0xc0000084, // SYSCALL_MASK (SFMASK)
    0xc0000100, // FS_BASE
    0xc0000101, // GS_BASE
    0xc0000102, // KERNEL_GS_BASE
    0x4b564d00, // MSR_KVM_WALL_CLOCK_NEW
    0x4b564d01, // MSR_KVM_SYSTEM_TIME_NEW
};

/// kvm_lapic_state: the in-kernel local APIC register page.
pub const LapicState = extern struct { regs: [1024]u8 };

/// kvm_xsave: FPU/SSE/AVX (and beyond) extended state. The fixed 4 KiB form.
pub const Xsave = extern struct { region: [1024]u32 };

pub const Xcr = extern struct { xcr: u32, reserved: u32 = 0, value: u64 = 0 };
pub const Xcrs = extern struct {
    nr_xcrs: u32,
    flags: u32 = 0,
    xcrs: [16]Xcr = undefined,
    padding: [16]u64 = [_]u64{0} ** 16,
};

/// kvm_vcpu_events: pending exception/interrupt/NMI/SMI injection state.
pub const VcpuEvents = extern struct {
    exception: extern struct { injected: u8, nr: u8, has_error_code: u8, pending: u8, error_code: u32 },
    interrupt: extern struct { injected: u8, nr: u8, soft: u8, shadow: u8 },
    nmi: extern struct { injected: u8, pending: u8, masked: u8, pad: u8 },
    sipi_vector: u32,
    flags: u32,
    smi: extern struct { smm: u8, pending: u8, smm_inside_nmi: u8, latched_init: u8 },
    reserved: [27]u8,
    exception_has_payload: u8,
    exception_payload: u64,
};

/// kvm_debugregs: DR0-DR3, DR6, DR7.
pub const Debugregs = extern struct {
    db: [4]u64,
    dr6: u64,
    dr7: u64,
    flags: u64,
    reserved: [9]u64,
};

/// kvm_clock_data: the paravirt clock value (VM-level). Current kernels carry
/// realtime + host_tsc after pad0 (used for cross-host clock reconstruction);
/// the struct is 48 bytes, and the ioctl number encodes that size.
pub const ClockData = extern struct {
    clock: u64,
    flags: u32,
    pad0: u32 = 0,
    realtime: u64 = 0,
    host_tsc: u64 = 0,
    pad: [4]u32 = [_]u32{0} ** 4,
};

// --- ioctl wrapper ---------------------------------------------------------

pub const Error = error{IoctlFailed};

/// Thin wrapper that decodes the KVM ioctl convention: a negative return is
/// `-errno`; anything else is a meaningful result (a new fd, a size, or 0).
pub fn ioctl(fd: i32, request: u32, arg: usize) Error!usize {
    const r = linux.ioctl(fd, request, arg);
    return switch (linux.errno(r)) {
        .SUCCESS => r,
        else => |e| {
            std.debug.print("[nether] ioctl 0x{x} failed: {s}\n", .{ request, @tagName(e) });
            return error.IoctlFailed;
        },
    };
}

// --- layout / ABI sanity checks --------------------------------------------

test "ioctl numbers match KVM ABI" {
    try std.testing.expectEqual(@as(u32, 0xAE00), GET_API_VERSION);
    try std.testing.expectEqual(@as(u32, 0xAE01), CREATE_VM);
    try std.testing.expectEqual(@as(u32, 0xAE04), GET_VCPU_MMAP_SIZE);
    try std.testing.expectEqual(@as(u32, 0xAE41), CREATE_VCPU);
    try std.testing.expectEqual(@as(u32, 0xAE80), RUN);
    try std.testing.expectEqual(@as(u32, 0x4020AE46), SET_USER_MEMORY_REGION);
    try std.testing.expectEqual(@as(u32, 0x8090AE81), GET_REGS);
    try std.testing.expectEqual(@as(u32, 0x4090AE82), SET_REGS);
    try std.testing.expectEqual(@as(u32, 0x8138AE83), GET_SREGS);
    try std.testing.expectEqual(@as(u32, 0x4138AE84), SET_SREGS);
    try std.testing.expectEqual(@as(u32, 0x8004AE98), GET_MP_STATE);
    try std.testing.expectEqual(@as(u32, 0x4004AE99), SET_MP_STATE);
}

test "struct sizes match kernel" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(UserspaceMemoryRegion));
    try std.testing.expectEqual(@as(usize, 144), @sizeOf(Regs));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Segment));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Dtable));
    try std.testing.expectEqual(@as(usize, 312), @sizeOf(Sregs));
    // The exit union begins at offset 32 in kvm_run.
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Run, "exit"));
}

test "interrupt struct sizes match kernel" {
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(EnableCap));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Irqfd));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Ioeventfd));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Msi));
}

test "snapshot struct sizes match kernel" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(MsrEntry));
    try std.testing.expectEqual(@as(usize, 1024), @sizeOf(LapicState));
    try std.testing.expectEqual(@as(usize, 4096), @sizeOf(Xsave));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Xcr));
    try std.testing.expectEqual(@as(usize, 392), @sizeOf(Xcrs));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(VcpuEvents));
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Debugregs));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(ClockData));
}

test "snapshot ioctl numbers match KVM ABI" {
    try std.testing.expectEqual(@as(u32, 0xC008AE88), GET_MSRS);
    try std.testing.expectEqual(@as(u32, 0x4008AE89), SET_MSRS);
    try std.testing.expectEqual(@as(u32, 0x8400AE8E), GET_LAPIC);
    try std.testing.expectEqual(@as(u32, 0x4400AE8F), SET_LAPIC);
    try std.testing.expectEqual(@as(u32, 0x8040AE9F), GET_VCPU_EVENTS);
    try std.testing.expectEqual(@as(u32, 0x4040AEA0), SET_VCPU_EVENTS);
    try std.testing.expectEqual(@as(u32, 0x8080AEA1), GET_DEBUGREGS);
    try std.testing.expectEqual(@as(u32, 0x9000AEA4), GET_XSAVE);
    try std.testing.expectEqual(@as(u32, 0x8188AEA6), GET_XCRS);
    try std.testing.expectEqual(@as(u32, 0x8030AE7C), GET_CLOCK);
    try std.testing.expectEqual(@as(u32, 0x4030AE7B), SET_CLOCK);
}

test "interrupt ioctl numbers match KVM ABI" {
    try std.testing.expectEqual(@as(u32, 0xAE03), CHECK_EXTENSION);
    try std.testing.expectEqual(@as(u32, 0x4068AEA3), ENABLE_CAP);
    try std.testing.expectEqual(@as(u32, 0x4020AE76), IRQFD);
    try std.testing.expectEqual(@as(u32, 0x4040AE79), IOEVENTFD);
    try std.testing.expectEqual(@as(u32, 0x4020AEA5), SIGNAL_MSI);
}
