//! Shared aarch64 device wiring for the HVF runner: the small thunks and the PCI
//! BAR-window dispatcher that both the boot path (main.zig macBootLinux) and the
//! restore path (snapshot.zig macRestore) use to stand up the PL011, virtio
//! console/blk, MSI/INTx delivery, and the host terminal. Factored out so snapshot
//! can build a guest without importing main (which would be a circular dependency).

const std = @import("std");
const nether = @import("../root.zig");
const libc = @import("../common/hostutil.zig").libc;
const conf = @import("../common/conf.zig");

// Standard arm64 "virt" memory map: RAM at 1 GiB, PL011 UART at 0x0900_0000.
pub const ARM_RAM_BASE: u64 = 0x4000_0000;
pub const ARM_UART_BASE: u64 = 0x0900_0000;
pub const ARM_RAM_SIZE: usize = 512 * nether.memmap.mib; // default; nether.conf ram_mb overrides
pub const ARM_DTB_OFF: u64 = 0x0800_0000;
pub const ARM_INITRD_OFF: u64 = 0x0C00_0000;
pub const ARM_NUM_CPUS: u32 = 4;
pub const ARM_MAX_CPUS: u32 = 8; // == hvf_backend.MAX_SNAP_CPUS; sizes the SMP arrays

/// PL011 TX sink: write one guest byte to host stdout (libc is linked on macOS).
pub fn uartOut(ctx: *anyopaque, byte: u8) void {
    _ = ctx;
    const b = [1]u8{byte};
    _ = std.c.write(1, &b, 1);
}

/// virtio-console TX sink: write guest hvc0 output straight to host stdout. The
/// bytes arrive via the virtqueue DMA datapath over the assigned BAR (not the
/// PL011), so seeing them is the end-to-end virtio-pci proof on aarch64.
pub fn consoleOut(ctx: *anyopaque, bytes: []const u8) void {
    _ = ctx;
    _ = std.c.write(1, bytes.ptr, bytes.len);
}

/// Backing store for the virtio-blk function (1 MiB, in .bss). Sector 0 carries a
/// signature so a guest `head -c /dev/vda` proves the block read datapath end to
/// end. Writes land here in memory (not persisted to a host file).
pub var blk_disk_storage: [1024 * 1024]u8 = undefined;
pub fn makeBlkDisk() []u8 {
    @memset(&blk_disk_storage, 0);
    const sig = "NETHER-VIRTIO-BLK-DISK-OK\n";
    @memcpy(blk_disk_storage[0..sig.len], sig);
    return &blk_disk_storage;
}

/// Legacy PCI INTx line for a virtio function (the fallback when the guest has no
/// MSI domain). The DTB interrupt-map routes (slot, INTA) to a GIC SPI via the
/// swizzle pci_intx_spi + ((slot + pin - 1) % 4); each device carries its own
/// IntxLine so the right SPI is asserted. INTx is unused once MSI-X is enabled.
pub fn armPciIntxIntid(slot: u32) u32 {
    return 32 + nether.memmap_arm.pci_intx_spi + ((slot + 1 - 1) % 4); // pin INTA = 1
}
pub const IntxLine = struct {
    intid: u32,
    pub fn set(ctx: *anyopaque, level: bool) void {
        const self: *IntxLine = @ptrCast(@alignCast(ctx));
        const hvf = @import("../hv/hvf.zig");
        _ = hvf.hv_gic_set_spi(self.intid, level);
    }
};

/// MSI-X delivery on HVF: forward the guest-programmed message (doorbell address
/// + data = the GICv2m-allocated SPI intid) to the framework GIC, which raises it
/// as if the device had written the doorbell.
pub fn armSendMsi(ctx: *anyopaque, addr: u64, data: u32) void {
    _ = ctx;
    const hvf = @import("../hv/hvf.zig");
    _ = hvf.hv_gic_send_msi(addr, data);
}

/// The PL011's SPI interrupt id: SPIs start at GIC INTID 32, and the DTB places
/// the UART at SPI `uart_spi`.
pub const ARM_UART_INTID: u32 = 32 + nether.memmap_arm.uart_spi;

/// PL011 interrupt line -> GIC SPI (level). Called from both the vCPU thread
/// (on DR drain) and the stdin thread (on RX); hv_gic_set_spi is global.
pub fn armUartIrq(ctx: *anyopaque, level: bool) void {
    _ = ctx;
    const hvf = @import("../hv/hvf.zig");
    _ = hvf.hv_gic_set_spi(ARM_UART_INTID, level);
}

/// Routes accesses across the whole 64-bit PCI MMIO window to the virtio device
/// whose *live* BAR0 contains the address. The kernel assigns each function's BAR
/// somewhere in the window, so we can't bind fixed sub-regions up front; instead
/// one window-wide dispatcher matches every access against each device's current
/// BAR base. Supports any number of functions on the bus.
pub const PciBarWindow = struct {
    devs: []const *nether.virtio.Device,

    pub fn device(self: *PciBarWindow) nether.MmioDevice {
        return .{
            .ptr = self,
            .base = nether.memmap_arm.pci_mmio64_base, // the 64-bit BAR window
            .len = nether.memmap_arm.pci_mmio64_size,
            .read_fn = read,
            .write_fn = write,
            // Routing is over the immutable device list and each virtio Device
            // self-serializes via its dev_lock, so run off the bus lock: concurrent
            // vCPUs hit different devices in parallel, and a notify's host I/O stays
            // off the global lock.
            .self_locked = true,
        };
    }
    fn match(self: *PciBarWindow, addr: u64) ?struct { dev: *nether.virtio.Device, off: u64 } {
        for (self.devs) |d| {
            const bar = d.barBase();
            if (bar != 0 and addr >= bar and addr - bar < nether.virtio.bar_size) {
                return .{ .dev = d, .off = addr - bar };
            }
        }
        return null;
    }
    fn read(ptr: *anyopaque, offset: u64, data: []u8) void {
        const self: *PciBarWindow = @ptrCast(@alignCast(ptr));
        if (self.match(nether.memmap_arm.pci_mmio64_base + offset)) |m| {
            const v = m.dev.barRead(m.off, @intCast(data.len));
            for (data, 0..) |*b, i| b.* = if (i < 4) @truncate(v >> @intCast(i * 8)) else 0;
        } else @memset(data, 0xFF);
    }
    fn write(ptr: *anyopaque, offset: u64, data: []const u8) void {
        const self: *PciBarWindow = @ptrCast(@alignCast(ptr));
        if (self.match(nether.memmap_arm.pci_mmio64_base + offset)) |m| {
            var v: u32 = 0;
            for (data, 0..) |b, i| {
                if (i < 4) v |= @as(u32, b) << @intCast(i * 8);
            }
            m.dev.barWrite(m.off, @intCast(data.len), v);
        }
    }
};

/// I/O thread: block on host stdin and push each chunk into the PL011 RX, which
/// raises the UART interrupt so the guest's tty driver reads it.
pub fn armStdinPump(uart: *nether.Pl011) void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n = libc.read(0, &buf, buf.len);
        if (n <= 0) return; // EOF or error
        uart.pushRx(buf[0..@intCast(n)]);
    }
}

/// Put the host tty in raw mode so keystrokes reach the guest unbuffered and
/// unechoed (the guest echoes). Returns the prior settings, or null for a
/// non-tty stdin (a pipe), which is left untouched.
pub fn armEnableRawMode() ?std.posix.termios {
    var t = std.posix.tcgetattr(0) catch return null;
    const saved = t;
    t.lflag.ICANON = false; // byte-at-a-time
    t.lflag.ECHO = false; // the guest echoes, not the host
    t.lflag.ISIG = false; // Ctrl-C/Z reach the guest
    t.lflag.IEXTEN = false;
    t.iflag.IXON = false; // Ctrl-S/Q reach the guest
    t.iflag.ICRNL = false; // deliver CR as CR
    t.iflag.BRKINT = false;
    t.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    t.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(0, .NOW, t) catch {};
    return saved;
}

pub fn armRestoreTermios(saved: std.posix.termios) void {
    std.posix.tcsetattr(0, .NOW, saved) catch {};
}

// --- virtio-net <-> slirp glue (shared by boot + restore) ------------------
// The user-mode network stack wiring, factored here so the restore path can stand
// up net the same way the boot path does (snapshot-fork driveability P4) without
// importing main. The slirp ENGINE always starts fresh on a fork - it holds real
// host sockets a forked process cannot inherit - so only these thunks + the
// per-sandbox firewall config are shared; flow state is never carried across.

/// Guest-transmitted frames go to the user-mode stack.
pub fn netToSlirp(ctx: *anyopaque, frame: []const u8) void {
    const s: *nether.Slirp = @ptrCast(@alignCast(ctx));
    s.onGuestFrame(frame);
}

/// Frames the stack produces are pushed back to the guest's RX queue.
pub fn slirpToNet(ctx: *anyopaque, frame: []const u8) void {
    const net: *nether.VirtioNet = @ptrCast(@alignCast(ctx));
    _ = net.pushRx(frame);
}

/// Host thread: poll the NAT sockets and inject replies into the guest.
pub fn slirpPollLoop(s: *nether.Slirp) void {
    while (true) s.pollOnce(200); // blocks up to 200ms in poll(); not a busy spin
}

/// Apply the egress-firewall config (govern) to a slirp stack from nether.conf:
/// default-deny private/loopback/link-local/metadata, `net_open` to disable,
/// `net_allow`/`net_block` CIDR exceptions, and a `net_rate_kbps` download cap.
/// Default-deny is the default, so an unconfigured stack is already firewalled.
pub fn applyNetFirewall(s: *nether.Slirp) void {
    if (conf.confBool("net_open")) s.fw_enabled = false;
    var fw_allow: [1024]u8 = undefined;
    if (conf.confGet("net_allow", &fw_allow)) |v| {
        var it = std.mem.splitScalar(u8, v, ',');
        while (it.next()) |c| {
            const t = std.mem.trim(u8, c, " \t");
            if (t.len > 0 and !s.addAllow(t)) std.debug.print("[nether] net_allow: bad/full rule '{s}'\n", .{t});
        }
    }
    var fw_block: [1024]u8 = undefined;
    if (conf.confGet("net_block", &fw_block)) |v| {
        var it = std.mem.splitScalar(u8, v, ',');
        while (it.next()) |c| {
            const t = std.mem.trim(u8, c, " \t");
            if (t.len > 0 and !s.addBlock(t)) std.debug.print("[nether] net_block: bad/full rule '{s}'\n", .{t});
        }
    }
    const rate_kbps = conf.confGetInt("net_rate_kbps", 0);
    if (rate_kbps > 0) s.setRateKbps(rate_kbps);
}
