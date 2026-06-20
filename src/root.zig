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
pub const memmap_arm = @import("memmap_arm.zig");
pub const dtb = @import("dtb.zig");
pub const irqchip = @import("irqchip.zig");
pub const acpi = @import("acpi.zig");
pub const elf = @import("elf.zig");
pub const pvh = @import("pvh.zig");

pub const pci = @import("pci.zig");
pub const PciHost = pci.Host;
pub const IoApic = @import("ioapic.zig").IoApic;

pub const Lock = @import("lock.zig").Lock;

/// Vendored VT parser (from ghostty, ported to 0.16). The state-machine heart
/// of a future server-side console / VT-aware golden tests. See src/vt/PORTING.md.
pub const vt = struct {
    pub const Parser = @import("vt/Parser.zig");
    pub const osc = @import("vt/osc.zig");
    pub const Screen = @import("vt/Screen.zig");
};

pub const webconsole = @import("webconsole.zig");
pub const WebConsole = webconsole.Server;

pub const trace = @import("trace.zig");
pub const virtq = @import("virtq.zig");
pub const virtio = @import("virtio.zig");
pub const VirtioRng = @import("virtio_rng.zig").Rng;
pub const VirtioBlk = @import("virtio_blk.zig").Blk;
pub const net = @import("virtio_net.zig");
pub const VirtioNet = net.Net;
pub const vsock = @import("virtio_vsock.zig");
pub const Vsock = vsock.Vsock;
pub const VsockDev = vsock.VsockDev;

const power = @import("power.zig");
pub const Power = power.Power;
pub const PowerAction = power.Action;

pub const Serial = @import("serial.zig").Serial;
pub const Pl011 = @import("pl011.zig").Pl011;
pub const Rtc = @import("rtc.zig").Rtc;
pub const Pm = @import("pm.zig").Pm;
pub const Reset = @import("reset.zig").Reset;
pub const FwCfg = @import("fw_cfg.zig").FwCfg;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("hvtypes.zig"); // backend-agnostic helpers (moved from vm.zig)
    _ = @import("pl011.zig"); // aarch64 PL011 UART
    _ = @import("dtb.zig"); // aarch64 device-tree generator
    // Pull in the vendored VT files so their tests run too.
    _ = @import("vt/Parser.zig");
    _ = @import("vt/parse_table.zig");
    _ = @import("vt/osc.zig");
    _ = @import("vt/Screen.zig");
    _ = @import("webconsole.zig");
    _ = @import("virtio_vsock.zig");
    _ = @import("virtio_net.zig");
    // Always-on fuzz-smoke for the guest-facing parsers (vt, virtqueue, vsock, net).
    _ = @import("fuzz.zig");
}
