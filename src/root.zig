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

pub const Lock = @import("common/lock.zig").Lock;

/// Vendored VT parser (from ghostty, ported to 0.16). The state-machine heart
/// of a future server-side console / VT-aware golden tests. See src/vt/PORTING.md.
pub const vt = struct {
    pub const Parser = @import("vt/Parser.zig");
    pub const osc = @import("vt/osc.zig");
    pub const Screen = @import("vt/Screen.zig");
};

/// The render pillar: a server-side terminal model of the agent's session, fed by
/// its output and snapshot via the `__screen__` control command.
pub const Render = @import("agent/render.zig").Render;
pub const audit = @import("agent/audit.zig");
pub const Journal = audit.Journal;

pub const webconsole = @import("agent/webconsole.zig");
pub const WebConsole = webconsole.Server;

pub const trace = @import("common/trace.zig");
pub const virtq = @import("virtio/virtq.zig");
pub const virtio = @import("virtio/virtio.zig");
pub const virtio_mmio = @import("virtio/virtio_mmio.zig");
pub const VirtioMmio = virtio_mmio.Mmio;
pub const VirtioRng = @import("virtio/virtio_rng.zig").Rng;
pub const VirtioBlk = @import("virtio/virtio_blk.zig").Blk;
pub const net = @import("virtio/virtio_net.zig");
pub const VirtioNet = net.Net;
pub const console = @import("virtio/virtio_console.zig");
pub const VirtioConsole = console.Console;
pub const VirtioGpu = @import("virtio/virtio_gpu.zig").Gpu;
pub const smp = @import("smp.zig");
pub const slirp = @import("slirp.zig");
pub const Slirp = slirp.Slirp;
pub const vsock = @import("virtio/virtio_vsock.zig");
pub const Vsock = vsock.Vsock;
pub const VsockDev = vsock.VsockDev;

const power = @import("common/power.zig");
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
    _ = @import("common/hvtypes.zig"); // backend-agnostic helpers (moved from vm.zig)
    _ = @import("pl011.zig"); // aarch64 PL011 UART
    _ = @import("dtb.zig"); // aarch64 device-tree generator
    _ = @import("virtio/virtio_mmio.zig"); // virtio-mmio transport
    // Pull in the vendored VT files so their tests run too.
    _ = @import("vt/Parser.zig");
    _ = @import("vt/parse_table.zig");
    _ = @import("vt/osc.zig");
    _ = @import("vt/Screen.zig");
    _ = @import("agent/render.zig");
    _ = @import("agent/webconsole.zig");
    _ = @import("virtio/virtio_vsock.zig");
    _ = @import("virtio/virtio_net.zig");
    _ = @import("virtio/virtio_console.zig");
    _ = @import("virtio/virtio_gpu.zig");
    _ = @import("smp.zig");
    _ = @import("slirp.zig");
    _ = @import("agent/control.zig");
    _ = @import("agent/audit.zig");
    _ = @import("agent/snapshot.zig"); // snapshot file-format validation (mac path)
    // Always-on fuzz-smoke for the guest-facing parsers (vt, virtqueue, vsock, net).
    _ = @import("fuzz.zig");
}
