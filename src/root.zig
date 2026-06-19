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
pub const PioDevice = io.PioDevice;
pub const MmioDevice = io.MmioDevice;

pub const memmap = @import("memmap.zig");
pub const irqchip = @import("irqchip.zig");
pub const acpi = @import("acpi.zig");
pub const elf = @import("elf.zig");
pub const pvh = @import("pvh.zig");

pub const pci = @import("pci.zig");
pub const PciHost = pci.Host;
pub const IoApic = @import("ioapic.zig").IoApic;

pub const Lock = @import("lock.zig").Lock;
pub const trace = @import("trace.zig");
pub const virtq = @import("virtq.zig");
pub const virtio = @import("virtio.zig");
pub const VirtioRng = @import("virtio_rng.zig").Rng;
pub const VirtioBlk = @import("virtio_blk.zig").Blk;

const power = @import("power.zig");
pub const Power = power.Power;
pub const PowerAction = power.Action;

pub const Serial = @import("serial.zig").Serial;
pub const Rtc = @import("rtc.zig").Rtc;
pub const Pm = @import("pm.zig").Pm;
pub const Reset = @import("reset.zig").Reset;
pub const FwCfg = @import("fw_cfg.zig").FwCfg;

test {
    @import("std").testing.refAllDecls(@This());
}
