//! Nether: the embeddable type-2 VMM core.
//!
//! This is the library root a host (e.g. swerver) consumes. The binary in
//! main.zig is a thin wrapper over exactly this surface.

pub const kvm = @import("kvm.zig");

const vm = @import("vm.zig");
pub const Vm = vm.Vm;
pub const Vcpu = vm.Vcpu;
pub const Region = vm.Region;
pub const Error = vm.Error;

pub const io = @import("io.zig");
pub const Bus = io.Bus;
pub const Device = io.Device;

pub const Serial = @import("serial.zig").Serial;

test {
    @import("std").testing.refAllDecls(@This());
}
