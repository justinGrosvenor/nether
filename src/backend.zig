//! Hypervisor backend selection - the hard compile-time seam.
//!
//! The backend follows the host OS, which also fixes the guest architecture:
//! Linux -> KVM -> x86-64 guests; macOS (Apple Silicon) -> HVF -> aarch64
//! guests. vm.zig wraps whichever `impl` is selected here behind a shared Vm
//! (guest-RAM mmap + region table + guest-memory accessors), so the rest of the
//! VMM is written against one Vm/Vcpu surface regardless of hypervisor.

const builtin = @import("builtin");

pub const impl = switch (builtin.os.tag) {
    .linux => @import("kvm_backend.zig"),
    .macos => @import("hvf_backend.zig"),
    else => @compileError("Nether needs a KVM (Linux) or HVF (macOS) host"),
};
