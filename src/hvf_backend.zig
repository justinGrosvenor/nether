//! HVF hypervisor backend (macOS / Apple Silicon, aarch64 guests). Peer of the
//! KVM backend, selected at comptime on macOS by backend.zig.
//!
//! STATUS: scaffold. The interface and types are in place so the shared Vm/Vcpu
//! wrapper, the device tree, and the offline test build all compile on macOS,
//! but the Hypervisor.framework calls are not wired yet - every operation
//! returns error.Unimplemented. The build-out arc (see docs/roadmap.md aarch64
//! track) is: hv_vm_create + hv_vm_map (guest RAM), hv_vcpu_create/run with
//! data-abort (MMIO) decode, the framework GIC (hv_gic) for interrupts, a PL011
//! UART + generic timer + PSCI firmware floor, and an Image+DTB boot path.
//!
//! The x86 boot-entry methods exist here only as inert stubs so the shared
//! Vcpu type and the (x86-only) PVH loader keep compiling on macOS; they are
//! never reached on HVF. aarch64 boot uses setAarch64Entry.

const std = @import("std");
const io = @import("io.zig");
const pwr = @import("power.zig");
const hvtypes = @import("hvtypes.zig");

const StopReason = hvtypes.StopReason;
const Error = hvtypes.Error;

pub const Vm = struct {
    pub fn init() Error!Vm {
        return error.Unimplemented;
    }

    pub fn deinit(self: *Vm) void {
        _ = self;
    }

    pub fn mapMemory(self: *Vm, slot: u32, guest_phys: u64, size: usize) Error![]u8 {
        _ = self;
        _ = slot;
        _ = guest_phys;
        _ = size;
        return error.Unimplemented;
    }

    pub fn unmapMemory(self: *Vm, host: []u8) void {
        _ = self;
        _ = host;
    }

    pub fn setupIrq(self: *Vm) Error!void {
        _ = self;
        return error.Unimplemented;
    }

    pub fn createVcpu(self: *Vm, id: u32) Error!Vcpu {
        _ = self;
        _ = id;
        return error.Unimplemented;
    }
};

pub const Vcpu = struct {
    pub fn deinit(self: *Vcpu) void {
        _ = self;
    }

    /// aarch64 boot entry: set PC to the kernel base and X0 to the DTB pointer
    /// (the Linux arm64 boot protocol). Wired in the HVF build-out.
    pub fn setAarch64Entry(self: *Vcpu, pc: u64, dtb: u64) Error!void {
        _ = self;
        _ = pc;
        _ = dtb;
        return error.Unimplemented;
    }

    pub fn run(self: *Vcpu, bus: *io.Bus, power: *pwr.Power) Error!StopReason {
        _ = self;
        _ = bus;
        _ = power;
        return error.Unimplemented;
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
