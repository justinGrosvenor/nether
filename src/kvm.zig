//! Minimal KVM ABI for Phase 0.
//!
//! Hand-rolled `extern struct` layouts and comptime-derived ioctl numbers for
//! exactly the surface the skeleton needs: create VM/vCPU, register one memory
//! region, set real-mode entry state, and run. This deliberately avoids
//! `@cImport("linux/kvm.h")` for now — see docs/decisions.md (D7): cImport pulls
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

pub const API_VERSION = 12;

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
        padding: [256]u8,
    },
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
