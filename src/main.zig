//! Nether binary: a thin wrapper over the embeddable core. If a `vmlinux` is
//! present in the working directory it is PVH-booted; otherwise a comptime
//! real-mode blob runs as a smoke test. Either way the firmware floor is wired
//! and the vCPU runs until the guest halts or powers off.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const nether = @import("root.zig");

// Host-OS primitives live in hostutil.zig; alias the ones the boot path still uses
// so the orchestration bodies below read unchanged.
const hostutil = @import("hostutil.zig");
const libc = hostutil.libc;
const usleep = hostutil.usleep;
const nowMs = hostutil.nowMs;
const writeAll = hostutil.writeAll;
const readExact = hostutil.readExact;
const readFileMac = hostutil.readFileMac;
const cpath = hostutil.cpath;
const SockaddrUn = hostutil.SockaddrUn;
const AF_UNIX = hostutil.AF_UNIX;
const SOCK_STREAM = hostutil.SOCK_STREAM;

// Per-sandbox config (nether.conf) lives in conf.zig.
const conf = @import("conf.zig");
const confGet = conf.confGet;
const confGetInt = conf.confGetInt;
const confBool = conf.confBool;
const modeOn = conf.modeOn;
const macMarkerPresent = conf.markerPresent;

// Control plane (control socket, agent plumbing, metering, lifecycle) lives in
// control.zig.
const control = @import("control.zig");
const Metering = control.Metering;
const AgentCtx = control.AgentCtx;
const ControlCtx = control.ControlCtx;
const AgentStdinCtx = control.AgentStdinCtx;
const agentEvent = control.agentEvent;
const controlListener = control.controlListener;
const controlRelay = control.controlRelay;
const agentStdinPump = control.agentStdinPump;
const stopSandbox = control.stopSandbox;

// Shared aarch64 device wiring (boot + restore) lives in armdev.zig.
const armdev = @import("armdev.zig");
const ARM_RAM_BASE = armdev.ARM_RAM_BASE;
const ARM_UART_BASE = armdev.ARM_UART_BASE;
const ARM_RAM_SIZE = armdev.ARM_RAM_SIZE;
const ARM_DTB_OFF = armdev.ARM_DTB_OFF;
const ARM_INITRD_OFF = armdev.ARM_INITRD_OFF;
const ARM_NUM_CPUS = armdev.ARM_NUM_CPUS;
const ARM_MAX_CPUS = armdev.ARM_MAX_CPUS;
const uartOut = armdev.uartOut;
const consoleOut = armdev.consoleOut;
const makeBlkDisk = armdev.makeBlkDisk;
const armPciIntxIntid = armdev.armPciIntxIntid;
const IntxLine = armdev.IntxLine;
const armSendMsi = armdev.armSendMsi;
const armUartIrq = armdev.armUartIrq;
const PciBarWindow = armdev.PciBarWindow;
const armStdinPump = armdev.armStdinPump;
const armEnableRawMode = armdev.armEnableRawMode;
const armRestoreTermios = armdev.armRestoreTermios;

// Snapshot/restore host orchestration lives in snapshot.zig.
const snapshot = @import("snapshot.zig");
const SnapCtx = snapshot.SnapCtx;
const macSnapshotter = snapshot.macSnapshotter;
const macRestore = snapshot.macRestore;

const GUEST_RAM_SIZE = 256 * nether.memmap.mib; // room for a kernel + initramfs
const CODE_LOAD_ADDR = 0x1000;

const message = "Nether lives. Phase 0: real-mode guest over COM1.\n";

/// Comptime-assemble a 16-bit real-mode program that prints `msg` byte by byte
/// to COM1, then triggers ACPI S5 soft-off. No loops or memory operands (just
/// `mov al, c; out dx, al` per character), so it is trivially correct. The S5
/// write drives the PM block end to end, so the run loop returns `.shutdown`.
fn buildBlob(comptime msg: []const u8) [3 + msg.len * 3 + 8]u8 {
    var buf: [3 + msg.len * 3 + 8]u8 = undefined;
    buf[0] = 0xBA; // mov dx, 0x3f8
    buf[1] = 0xF8;
    buf[2] = 0x03;
    var i: usize = 3;
    for (msg) |c| {
        buf[i] = 0xB0; // mov al, imm8
        buf[i + 1] = c;
        buf[i + 2] = 0xEE; // out dx, al
        i += 3;
    }
    // ACPI S5 soft-off: write SLP_EN | (SLP_TYP=5) to PM1a_CNT (port 0x604).
    buf[i] = 0xBA; // mov dx, 0x604
    buf[i + 1] = 0x04;
    buf[i + 2] = 0x06;
    buf[i + 3] = 0xB8; // mov ax, 0x3400  (SLP_EN=0x2000 | 5<<10)
    buf[i + 4] = 0x00;
    buf[i + 5] = 0x34;
    buf[i + 6] = 0xEF; // out dx, ax
    buf[i + 7] = 0xF4; // hlt (fallback if shutdown does not fire)
    return buf;
}

/// The entry forks by host OS at comptime: Linux drives the KVM/x86 path, macOS
/// the HVF/aarch64 path. Only the selected branch is analyzed, so each side may
/// use its own platform syscalls freely.
pub fn main() !void {
    switch (builtin.os.tag) {
        .linux => try linuxMain(),
        .macos => try macMain(),
        else => @compileError("Nether needs a Linux (KVM) or macOS (HVF) host"),
    }
}

fn linuxMain() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    nether.trace.init(); // device tracing on if a `nether-trace` file is present

    var vm = try nether.Vm.init(allocator);
    defer vm.deinit();

    // Split irqchip: in-kernel LAPIC, userspace IOAPIC/PIC. Before any vCPU.
    try vm.enableSplitIrqchip();

    // The memory map is the single source of truth; register every RAM region
    // it produces. Low RAM holds the boot blob.
    const layout = nether.memmap.Layout.compute(GUEST_RAM_SIZE);
    const low = try vm.addMemory(0, layout.ram_low.base, layout.ram_low.size);
    if (layout.ram_high) |hi| _ = try vm.addMemory(1, hi.base, hi.size);

    // Firmware floor: serial, RTC, the ACPI PM block, and the 0xCF9 reset port.
    var ioapic = nether.IoApic{ .vm_fd = vm.hv.vm_fd };

    var power = nether.Power{};
    var serial = nether.Serial{};
    serial.irq = &ioapic;
    // Host stdin is driven into the serial RX by a dedicated I/O thread (set up
    // below, once we know a kernel is booting), not polled on the vCPU thread.
    // Console tee: mirror the guest's serial output into a screen grid so the VMM
    // holds a live render (dumped on exit under trace; the basis for a future
    // snapshot / web console). 80x24 standard, single-writer on the vCPU thread.
    var console = try nether.vt.Screen.init(allocator, 24, 80);
    defer console.deinit();
    var console_lock = nether.Lock{}; // guards the console between the tee and the web reader
    serial.mirror = &console;
    serial.mirror_lock = &console_lock;
    var rtc = nether.Rtc{};
    var pm = nether.Pm{ .power = &power };
    var reset = nether.Reset{ .power = &power };
    var fw = nether.FwCfg{};

    var pci_host = nether.PciHost{};

    var bus = nether.Bus{};
    try bus.addPio(serial.device());
    try bus.addPio(rtc.device());
    try bus.addPio(pm.device());
    try bus.addPio(reset.device());
    try bus.addPio(fw.device());
    try bus.addMmio(ioapic.mmioDevice()); // userspace IOAPIC at 0xFEC00000
    try bus.addMmio(pci_host.mmioDevice()); // PCIe ECAM

    // virtio-blk: present /dev/vda if a disk.img is available. The device is PCI
    // function 0:1.0 with its BAR pre-assigned in the pci-mmio32 window (the
    // guest claims it via the ACPI _CRS), and completions delivered by MSI-X.
    var blk: nether.VirtioBlk = undefined;
    var blk_dev: nether.virtio.Device = undefined;
    var msi_sink = MsiSink{ .vm_fd = vm.hv.vm_fd };
    if (mapFile("disk.img")) |disk| {
        blk = .{ .disk = disk };
        blk_dev = nether.virtio.Device.init(blk.backend(), .{ .bytes = low, .base = layout.ram_low.base });
        blk_dev.assignBar(nether.memmap.pci_mmio32_base);
        blk_dev.msi_ptr = &msi_sink;
        blk_dev.msi_fn = MsiSink.send;
        try pci_host.addFunction(blk_dev.function(1, 0));
        try bus.addMmio(blk_dev.mmio());
        std.debug.print("[nether] virtio-blk: disk.img {d} bytes, BAR 0x{x}\n", .{ disk.len, blk_dev.barBase() });
    }

    // virtio-vsock: the swerver<->guest channel. Opt-in via a `nether-vsock`
    // marker. PCI function 0:2.0, BAR clear of virtio-blk's (base + 64 KiB), with
    // a guest CID of 3 (host is 2). As a live exerciser the host listens on port
    // 1234 and echoes; the engine is heap-allocated (it is large and snapshot
    // state), the transport/glue are stack locals that outlive `run`.
    var vsock_engine: ?*nether.Vsock = null;
    defer if (vsock_engine) |v| allocator.destroy(v);
    var vsdev: nether.VsockDev = undefined;
    var vs_dev: nether.virtio.Device = undefined;
    if (vsockEnabled()) {
        const vs = try allocator.create(nether.Vsock);
        vs.* = .{ .guest_cid = 3 };
        vs.on_event = vsockEcho;
        vs.on_event_ctx = vs;
        vsock_engine = vs;
        vsdev = .{ .engine = vs };
        vs_dev = nether.virtio.Device.init(vsdev.backend(), .{ .bytes = low, .base = layout.ram_low.base });
        vs_dev.assignBar(nether.memmap.pci_mmio32_base + 0x10000);
        vs_dev.msi_ptr = &msi_sink;
        vs_dev.msi_fn = MsiSink.send;
        try pci_host.addFunction(vs_dev.function(2, 0));
        try bus.addMmio(vs_dev.mmio());
        vsdev.attach(&vs_dev);
        _ = vsdev.hostListen(1234);
        std.debug.print("[nether] virtio-vsock: guest CID 3, echo on port 1234, BAR 0x{x}\n", .{vs_dev.barBase()});
    }

    // virtio-net: opt-in via a `nether-net` marker, backed by a host tap device
    // (`tap0`, which the host must pre-create and configure). PCI function 0:3.0,
    // BAR clear of blk/vsock (base + 128 KiB). Guest TX frames are written to the
    // tap; a reader thread (spawned below) pushes inbound frames to the guest RX.
    var net_be: nether.VirtioNet = undefined;
    var net_dev: nether.virtio.Device = undefined;
    var tap_io: TapIo = undefined;
    var net_running = false;
    if (netEnabled()) {
        if (openTap("tap0")) |tap_fd| {
            net_be = .{};
            net_dev = nether.virtio.Device.init(net_be.backend(), .{ .bytes = low, .base = layout.ram_low.base });
            net_dev.assignBar(nether.memmap.pci_mmio32_base + 0x20000);
            net_dev.msi_ptr = &msi_sink;
            net_dev.msi_fn = MsiSink.send;
            try pci_host.addFunction(net_dev.function(3, 0));
            try bus.addMmio(net_dev.mmio());
            net_be.attach(&net_dev);
            tap_io = .{ .fd = tap_fd, .net = &net_be };
            net_be.on_tx = TapIo.tx;
            net_be.on_tx_ctx = &tap_io;
            net_running = true;
            std.debug.print("[nether] virtio-net: tap0, MAC 52:54:00:12:34:56, BAR 0x{x}\n", .{net_dev.barBase()});
        } else {
            std.debug.print("[nether] virtio-net: cannot open tap0 (need /dev/net/tun and a configured tap)\n", .{});
        }
    }

    var vcpu = try vm.createVcpu(0);
    defer vcpu.deinit();

    // Boot a PVH kernel if `vmlinux` is present; otherwise run the demo blob.
    const kernel: ?[]u8 = readFile(allocator, "vmlinux") catch null;
    if (kernel) |k| {
        defer allocator.free(k);
        const initramfs: ?[]u8 = readFile(allocator, "initramfs") catch null;
        defer if (initramfs) |fs| allocator.free(fs);
        nether.pvh.boot(&vm, &vcpu, layout, k, "console=ttyS0,115200 earlyprintk=serial,ttyS0,115200 nokaslr no_timer_check", initramfs) catch |err| {
            std.debug.print("[nether] PVH boot failed: {s}\n", .{@errorName(err)});
            return err;
        };
        std.debug.print("[nether] PVH: booting vmlinux ({d} bytes), initramfs {d} bytes\n", .{ k.len, if (initramfs) |fs| fs.len else 0 });
    } else {
        const blob = comptime buildBlob(message);
        @memcpy(low[CODE_LOAD_ADDR .. CODE_LOAD_ADDR + blob.len], blob[0..]);
        try vcpu.setRealModeEntry(CODE_LOAD_ADDR);
    }

    // Interactive console: put the host terminal in raw mode (so each keystroke
    // reaches the guest, which does its own echo and line editing) and run a
    // dedicated I/O thread that blocks on stdin and feeds the serial RX. Only for
    // a real kernel; the demo blob never reads input. Both are best-effort: a
    // non-tty stdin (pipe) just skips raw mode, and a spawn failure degrades to
    // an output-only console.
    var saved_termios: ?linux.termios = null;
    if (kernel != null) {
        saved_termios = enableRawMode(0);
        if (std.Thread.spawn(.{}, stdinPump, .{&serial})) |t| {
            t.detach(); // blocked on read; reclaimed at process exit
        } else |err| {
            std.debug.print("[nether] stdin thread failed: {s}; console is output-only\n", .{@errorName(err)});
        }
    }
    defer if (saved_termios) |s| restoreTermios(0, s);

    // Web console: opt-in via a `nether-web` marker file (like trace). Serves the
    // live console grid over HTTP on a detached thread. `web` is a stack local
    // that outlives run; the thread is reclaimed at process exit.
    var web_buf: []u8 = &.{};
    defer if (web_buf.len > 0) allocator.free(web_buf);
    var web: nether.WebConsole = undefined;
    if (webEnabled()) {
        web_buf = try allocator.alloc(u8, 256 * 1024);
        web = .{
            .screen = &console,
            .lock = &console_lock,
            .port = 9000,
            .buf = web_buf,
            .on_input = webInput,
            .on_input_ctx = &serial,
        };
        if (std.Thread.spawn(.{}, nether.WebConsole.run, .{&web})) |t| {
            t.detach();
            std.debug.print("[nether] web console: http://0.0.0.0:9000\n", .{});
        } else |err| {
            std.debug.print("[nether] web console failed: {s}\n", .{@errorName(err)});
        }
    }

    // virtio-net tap reader: a detached thread blocks on the tap fd and pushes
    // each inbound frame to the guest's RX ring (frames are dropped until the
    // guest posts buffers, which is harmless). Same lifetime model as the stdin
    // and web threads: the process owns it.
    if (net_running) {
        if (std.Thread.spawn(.{}, TapIo.rxPump, .{&tap_io})) |t| {
            t.detach();
        } else |err| {
            std.debug.print("[nether] net rx thread failed: {s}; net is send-only\n", .{@errorName(err)});
        }
    }

    const reason = vcpu.run(&bus, &power, &ioapic) catch |err| {
        std.debug.print("[nether] vcpu stopped: {s}\n", .{@errorName(err)});
        if (nether.trace.on()) dumpConsole(&console);
        return err;
    };
    std.debug.print("\n[nether] guest {s}.\n", .{@tagName(reason)});
    if (nether.trace.on()) dumpConsole(&console);
}

/// Web console input sink: deliver browser keystrokes to the serial RX (the same
/// path the stdin thread uses). pushRx is internally locked, so calling it from
/// the web thread is safe.
fn webInput(ctx: *anyopaque, bytes: []const u8) void {
    const serial: *nether.Serial = @ptrCast(@alignCast(ctx));
    serial.pushRx(bytes);
}

/// True if a `nether-web` marker file is present in the working directory.
fn webEnabled() bool {
    return markerPresent("nether-web");
}

/// True if a `nether-vsock` marker file is present in the working directory.
fn vsockEnabled() bool {
    return markerPresent("nether-vsock");
}

/// True if a `nether-net` marker file is present in the working directory.
fn netEnabled() bool {
    return markerPresent("nether-net");
}

fn markerPresent(path: [*:0]const u8) bool {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    _ = linux.close(@intCast(fd));
    return true;
}

/// vsock exerciser: echo whatever the guest sends back to it. Runs as the
/// engine's `on_event` callback, which fires inside `engine.rx()` while the
/// device lock is held, so it replies via the engine directly (not the locking
/// host* API) per the VsockDev re-entrancy contract; the kick that delivered the
/// data flushes the echo to the guest before returning.
/// virtio-net <-> slirp glue: guest-transmitted frames go to the user-mode stack,
/// and frames the stack produces are pushed back to the guest's RX queue.
fn netToSlirp(ctx: *anyopaque, frame: []const u8) void {
    const s: *nether.Slirp = @ptrCast(@alignCast(ctx));
    s.onGuestFrame(frame);
}
fn slirpToNet(ctx: *anyopaque, frame: []const u8) void {
    const net: *nether.VirtioNet = @ptrCast(@alignCast(ctx));
    _ = net.pushRx(frame);
}
fn slirpPollLoop(s: *nether.Slirp) void {
    while (true) s.pollOnce(200); // blocks up to 200ms in poll(); not a busy spin
}

fn vsockEcho(ctx: *anyopaque, ev: nether.vsock.Event) void {
    const vs: *nether.Vsock = @ptrCast(@alignCast(ctx));
    switch (ev) {
        .recv => |r| _ = vs.send(r.conn, r.bytes),
        else => {},
    }
}

/// Print the teed console grid (non-empty rows) to stderr. Gated by trace so it
/// is opt-in; the grid is always maintained, this just surfaces it on exit.
fn dumpConsole(scr: *nether.vt.Screen) void {
    const total = scr.viewRows();
    std.debug.print("[nether] console {d}x{d}, {d} scrollback rows:\n", .{ scr.rows, scr.cols, scr.scrollbackLen() });
    var buf: [4096]u8 = undefined;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const line = std.mem.trimEnd(u8, scr.viewRow(i, &buf), " ");
        if (line.len > 0) std.debug.print("  {s}\n", .{line});
    }
}

/// virtio-net tap plumbing: the host side of the NIC. Guest TX frames are
/// written to the tap fd; a reader thread pushes inbound frames to the guest.
const TapIo = struct {
    fd: i32,
    net: *nether.VirtioNet,

    /// on_tx sink (vCPU thread): write a guest frame to the tap. Best-effort,
    /// like a NIC dropping on a full queue; runs outside the device lock.
    fn tx(ctx: *anyopaque, frame: []const u8) void {
        const self: *TapIo = @ptrCast(@alignCast(ctx));
        _ = linux.write(self.fd, frame.ptr, frame.len);
    }

    /// I/O thread body: block on the tap and push each frame to the guest RX.
    fn rxPump(self: *TapIo) void {
        var buf: [nether.net.FRAME_MAX]u8 = undefined;
        while (true) {
            const n = linux.read(self.fd, &buf, buf.len);
            switch (linux.errno(n)) {
                .SUCCESS => {},
                .INTR, .AGAIN => continue,
                else => return,
            }
            if (n == 0) return; // tap closed
            _ = self.net.pushRx(buf[0..n]);
        }
    }
};

/// Open `/dev/net/tun` and bind it to an existing tap interface in TAP mode with
/// no packet-info prefix, so reads/writes are raw Ethernet frames. Returns null
/// if the tun device or the interface is unavailable.
fn openTap(name: []const u8) ?i32 {
    const fd_u = linux.open("/dev/net/tun", .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(fd_u) != .SUCCESS) return null;
    const fd: i32 = @intCast(fd_u);
    // struct ifreq: char ifr_name[16]; then ifr_flags (u16); padded to 40 bytes.
    var ifr = [_]u8{0} ** 40;
    const m = @min(name.len, 15);
    @memcpy(ifr[0..m], name[0..m]);
    const IFF_TAP: u16 = 0x0002;
    const IFF_NO_PI: u16 = 0x1000;
    std.mem.writeInt(u16, ifr[16..18], IFF_TAP | IFF_NO_PI, .little);
    const TUNSETIFF: u32 = 0x400454ca; // _IOW('T', 202, int)
    if (linux.errno(linux.ioctl(fd, TUNSETIFF, @intFromPtr(&ifr))) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

/// Delivers a virtio MSI-X completion by injecting it through KVM.
const MsiSink = struct {
    vm_fd: i32,
    fn send(ptr: *anyopaque, addr: u64, data: u32) void {
        const self: *MsiSink = @ptrCast(@alignCast(ptr));
        nether.irqchip.signalMsi(self.vm_fd, addr, data) catch {};
    }
};

/// I/O thread body: block on host stdin and push every chunk into the serial
/// RX FIFO, which raises IRQ4 so an idle guest wakes to read it. Exits on EOF or
/// a hard read error; the process owns the lifetime (it is detached).
fn stdinPump(serial: *nether.Serial) void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n = linux.read(0, &buf, buf.len);
        switch (linux.errno(n)) {
            .SUCCESS => {},
            .INTR, .AGAIN => continue,
            else => return,
        }
        if (n == 0) return; // EOF
        serial.pushRx(buf[0..n]);
    }
}

/// Put `fd` into raw mode (no canonical line editing, no host echo, signals
/// passed through to the guest) and return the prior settings to restore on
/// exit. Returns null when `fd` is not a tty (a pipe/file), leaving it untouched.
fn enableRawMode(fd: i32) ?linux.termios {
    var t: linux.termios = undefined;
    if (linux.errno(linux.ioctl(fd, linux.T.CGETS, @intFromPtr(&t))) != .SUCCESS) return null;
    const saved = t;
    t.lflag.ICANON = false; // byte-at-a-time, no line buffering
    t.lflag.ECHO = false; // the guest echoes, not the host
    t.lflag.ISIG = false; // Ctrl-C/Z reach the guest shell
    t.lflag.IEXTEN = false;
    t.iflag.IXON = false; // Ctrl-S/Q reach the guest
    t.iflag.ICRNL = false; // deliver CR as CR, let the guest map it
    t.iflag.BRKINT = false;
    t.iflag.INPCK = false;
    t.iflag.ISTRIP = false;
    // Output flags (oflag) are left alone: stdout shares this tty, and the guest
    // console relies on ONLCR to turn its '\n' into CRLF.
    t.cc[@intFromEnum(linux.V.MIN)] = 1; // read returns after >= 1 byte
    t.cc[@intFromEnum(linux.V.TIME)] = 0;
    _ = linux.ioctl(fd, linux.T.CSETS, @intFromPtr(&t));
    return saved;
}

fn restoreTermios(fd: i32, saved: linux.termios) void {
    var s = saved;
    _ = linux.ioctl(fd, linux.T.CSETS, @intFromPtr(&s));
}

/// mmap a file read/write and shared, so guest writes reach the backing image.
fn mapFile(path: [*:0]const u8) ?[]u8 {
    const fd_u = linux.open(path, .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(fd_u) != .SUCCESS) return null;
    const fd: i32 = @intCast(fd_u);
    defer _ = linux.close(fd);
    const size_r = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(size_r) != .SUCCESS or size_r == 0) return null;
    const size: usize = @intCast(size_r);
    const addr = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (linux.errno(addr) != .SUCCESS) return null;
    const ptr: [*]u8 = @ptrFromInt(addr);
    return ptr[0..size];
}

/// Read an entire file via raw linux syscalls (avoids the std.Io/args churn).
/// Caller owns the returned slice.
fn readFile(allocator: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const fd_u = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    switch (linux.errno(fd_u)) {
        .SUCCESS => {},
        else => return error.OpenFailed,
    }
    const fd: i32 = @intCast(fd_u);
    defer _ = linux.close(fd);

    var buf = try allocator.alloc(u8, 1 << 20);
    errdefer allocator.free(buf);
    var total: usize = 0;
    while (true) {
        if (total == buf.len) buf = try allocator.realloc(buf, buf.len * 2);
        const n = linux.read(fd, buf.ptr + total, buf.len - total);
        switch (linux.errno(n)) {
            .SUCCESS => {},
            else => return error.ReadFailed,
        }
        if (n == 0) break;
        total += n;
    }
    return allocator.realloc(buf, total);
}

// === macOS / HVF / aarch64 ==================================================

const arm_message = "Nether lives. Phase 0: aarch64 guest over MMIO UART.\n";

/// macOS/HVF entry: boot an arm64 Linux `Image` from kernels/ if present,
/// otherwise run the first-light blob demo.
fn macMain() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    nether.trace.init();

    // A `nether-restore` marker forks a guest from a snapshot instead of booting.
    // `restore_from=<path>` in nether.conf selects the base image (defaults to
    // nether.snap), so the platform can pre-bake several base snapshots
    // (python-base.snap, node-base.snap, ...) and fork the right one per sandbox.
    if (modeOn("restore", "nether-restore")) {
        var path_buf: [1024]u8 = undefined;
        const path: [*:0]const u8 = if (confGet("restore_from", &path_buf)) |p|
            @ptrCast(p.ptr)
        else
            "nether.snap";
        try macRestore(allocator, path);
        return;
    }

    if (readFileMac(allocator, "kernels/Image") catch null) |kernel| {
        defer allocator.free(kernel);
        // Prefer our own busybox/Alpine initramfs (boots to a usable shell); fall
        // back to Alpine's netboot initramfs (which drops to recovery).
        const initramfs: ?[]const u8 = blk: {
            if (readFileMac(allocator, "kernels/initramfs.cpio.gz") catch null) |fs| break :blk fs;
            break :blk readFileMac(allocator, "kernels/initramfs-virt") catch null;
        };
        defer if (initramfs) |fs| allocator.free(fs);
        try macBootLinux(allocator, kernel, initramfs);
    } else {
        try macBlobDemo(allocator);
    }
}

/// Boot an arm64 Linux kernel: place the Image, DTB, and initramfs in guest RAM,
/// create the GIC, and enter the kernel with X0 = DTB (the arm64 boot protocol).
fn macBootLinux(allocator: std.mem.Allocator, kernel: []const u8, initramfs: ?[]const u8) !void {
    const hvf = @import("hvf.zig");
    const hvfb = @import("hvf_backend.zig");

    // Per-sandbox sizing from nether.conf (cpus, ram_mb), with sane clamps. RAM is
    // kept >= 256 MiB so the DTB/initrd offsets (192 MiB) fit.
    const num_cpus: u32 = @intCast(std.math.clamp(confGetInt("cpus", ARM_NUM_CPUS), 1, ARM_MAX_CPUS));
    const ram_size: usize = @intCast(@max(confGetInt("ram_mb", ARM_RAM_SIZE / nether.memmap.mib), 256) * nether.memmap.mib);

    // Per-sandbox metering (declared early so the net block can point it at the
    // NAT for egress byte counts; read by the __stats__ control command).
    var meter = Metering{ .start_ms = nowMs(), .ram_mb = ram_size / (1024 * 1024), .cpus = num_cpus };

    var vm = try nether.Vm.init(allocator);
    defer vm.deinit();
    const ram = try vm.addMemory(0, ARM_RAM_BASE, ram_size);
    try vm.enableSplitIrqchip(); // hv_gic_create, before the vCPU

    // The boot vCPU must exist before we can ask where the framework placed its
    // GIC redistributor; the DTB has to describe that actual address.
    var vcpu = try vm.createVcpu(0);
    defer vcpu.deinit();

    // SMP: one Cpu control block per core (boot core already "started"), and a
    // secondary thread per extra core. Each secondary CREATES its own vCPU (HVF
    // binds a vCPU to its creating thread) so all redistributors exist before the
    // kernel's GIC init, then parks until PSCI CPU_ON releases it.
    var cpus_buf: [ARM_MAX_CPUS]nether.smp.Cpu = undefined;
    const cpus = cpus_buf[0..num_cpus];
    for (cpus, 0..) |*c, i| c.* = .{ .mpidr = 0x8000_0000 | @as(u64, i) };
    cpus[0].started.store(true, .release); // boot core
    var smpc = nether.smp.Smp{ .cpus = cpus };
    var created = std.atomic.Value(u32).init(0); // secondaries that finished createVcpu
    var sec_ctx: [ARM_MAX_CPUS]SmpCtx = undefined;
    var power = nether.Power{};
    var bus = nether.Bus{};
    var snapctl = hvfb.SnapCtl{}; // snapshot/restore rendezvous across vCPU threads
    var handles: [ARM_MAX_CPUS]u64 = undefined; // vCPU handles for hv_vcpus_exit
    handles[0] = vcpu.handle;

    var ci: u32 = 1;
    while (ci < num_cpus) : (ci += 1) {
        sec_ctx[ci] = .{ .vm = &vm, .id = ci, .cpu = &cpus[ci], .bus = &bus, .power = &power, .smpc = &smpc, .created = &created, .handles = &handles, .snap = &snapctl };
        (std.Thread.spawn(.{}, macSecondaryCpu, .{&sec_ctx[ci]}) catch |err| {
            std.debug.print("[nether] secondary cpu {d} spawn failed: {s}\n", .{ ci, @errorName(err) });
            return err;
        }).detach();
    }
    // Wait until every secondary has created its vCPU (so all GIC redistributors
    // are present) before building the DTB and starting the boot core.
    while (created.load(.acquire) < num_cpus - 1) _ = usleep(200);

    const queried = vcpu.redistributorBase();
    const gicr_base = if (queried != 0) queried else nether.memmap_arm.gicr_base;

    @memcpy(ram[0..kernel.len], kernel); // Image at the RAM base

    var initrd_start: u64 = 0;
    var initrd_end: u64 = 0;
    if (initramfs) |fs| {
        @memcpy(ram[ARM_INITRD_OFF..][0..fs.len], fs);
        initrd_start = ARM_RAM_BASE + ARM_INITRD_OFF;
        initrd_end = initrd_start + fs.len;
    }

    var dtb_buf: [16 * 1024]u8 = undefined;
    const dtb_len = nether.dtb.buildVirt(&dtb_buf, .{
        .cmdline = "console=ttyAMA0 earlycon=pl011,0x9000000",
        .mem_base = ARM_RAM_BASE,
        .mem_size = ram_size,
        .gicd_size = vm.hv.gicd_size,
        .gicr_base = gicr_base,
        .gicr_size = vm.hv.gicr_size,
        .initrd_start = initrd_start,
        .initrd_end = initrd_end,
        .num_cpus = num_cpus,
        .pcie = .{
            .ecam_base = nether.memmap_arm.ecam_base,
            .ecam_size = nether.memmap_arm.ecam_size,
            .io_base = nether.memmap_arm.pci_io_base,
            .io_size = nether.memmap_arm.pci_io_size,
            .mmio_base = nether.memmap_arm.pci_mmio_base,
            .mmio_size = nether.memmap_arm.pci_mmio_size,
            .mmio64_base = nether.memmap_arm.pci_mmio64_base,
            .mmio64_size = nether.memmap_arm.pci_mmio64_size,
        },
        .msi = .{
            .doorbell_base = nether.memmap_arm.msi_base,
            .doorbell_size = 0x1000,
            .spi_base = vm.hv.msi_spi_base,
            .spi_count = vm.hv.msi_spi_count,
        },
    });
    @memcpy(ram[ARM_DTB_OFF..][0..dtb_len], dtb_buf[0..dtb_len]);

    hvf.sys_icache_invalidate(ram.ptr, kernel.len); // host write -> guest I-fetch

    var uart = nether.Pl011{};
    uart.out_fn = uartOut;
    uart.out_ctx = &uart;
    uart.irq_fn = armUartIrq; // RX data raises the PL011 SPI through the GIC
    uart.irq_ctx = &uart;
    try bus.addMmio(uart.device(ARM_UART_BASE));

    // virtio-pci: a generic-ECAM PCIe host bridge carrying multiple virtio
    // functions, reusing the same PCI transport + backends + virtq as the x86
    // path. The guest RAM view (where the queues live) is `ram` based at
    // ARM_RAM_BASE. Each function gets the standard wiring: MSI-X (preferred, via
    // the GICv2m frame) and a per-slot INTx fallback; the kernel assigns each
    // BAR somewhere in the 64-bit window and one PciBarWindow dispatches to all.
    const gmem = nether.virtq.GuestMem{ .bytes = ram, .base = ARM_RAM_BASE };
    var pci_host = nether.PciHost{ .ecam_base = nether.memmap_arm.ecam_base, .ecam_size = nether.memmap_arm.ecam_size };

    // Function 0:1.0 - virtio-console (binds the built-in driver -> /dev/hvc0).
    var con = nether.VirtioConsole{};
    con.out_fn = consoleOut; // guest hvc0 output -> host stdout
    con.out_ctx = &con;
    var con_dev = nether.virtio.Device.init(con.backend(), gmem);
    con.attach(&con_dev);
    var con_intx = IntxLine{ .intid = armPciIntxIntid(1) };
    con_dev.intx_ptr = &con_intx;
    con_dev.intx_fn = IntxLine.set;
    con_dev.msi_ptr = &con_dev;
    con_dev.msi_fn = armSendMsi;
    try pci_host.addFunction(con_dev.function(1, 0));

    // Function 0:2.0 - virtio-blk backed by an in-memory disk with a recognizable
    // signature, exercised by loading virtio_blk.ko in the guest (-> /dev/vda).
    // Proves a second virtio function on the same bus (own BAR + MSI-X vectors).
    var blk = nether.VirtioBlk{ .disk = makeBlkDisk() };
    var blk_dev = nether.virtio.Device.init(blk.backend(), gmem);
    var blk_intx = IntxLine{ .intid = armPciIntxIntid(2) };
    blk_dev.intx_ptr = &blk_intx;
    blk_dev.intx_fn = IntxLine.set;
    blk_dev.msi_ptr = &blk_dev;
    blk_dev.msi_fn = armSendMsi;
    try pci_host.addFunction(blk_dev.function(2, 0));

    // Function 0:3.0 - virtio-vsock, the host<->guest control channel (opt-in via
    // a `nether-vsock` marker). Guest CID 3, host CID 2; the host listens on port
    // 1234 and echoes. The engine is heap-allocated (large, connection state); the
    // transport/glue are stack locals that outlive `run`.
    var vs_engine: ?*nether.Vsock = null;
    defer if (vs_engine) |v| allocator.destroy(v);
    var vsdev: nether.VsockDev = undefined;
    var vs_dev: nether.virtio.Device = undefined;
    var vs_intx: IntxLine = undefined;
    var agent_ctx = AgentCtx{};
    // Unified event journal (observe): one sequenced timeline of commands, network
    // flows, and lifecycle events, polled via __events__. Shared by the agent (CMD),
    // slirp (NET), and lifecycle emitters.
    var journal = nether.Journal{};
    agent_ctx.journal = &journal;
    journal.emit(.life, "boot");
    // Control socket path from nether.conf (per-sandbox), else the default. A
    // configured path also enables control mode (no marker needed).
    var sock_path_buf: [256]u8 = undefined;
    const have_sock_conf = confGet("control_socket", &sock_path_buf) != null;
    const ctl_path: [*:0]const u8 = if (have_sock_conf) @ptrCast(&sock_path_buf) else "/tmp/nether.sock";
    const control_on = modeOn("control", "nether-control") or have_sock_conf;
    const agent_repl = modeOn("agent", "nether-agent") and !control_on;
    const agent_mode = control_on or agent_repl; // both drive the agent via agentEvent
    const vsock_on = modeOn("vsock", "nether-vsock") or agent_mode;

    // Render pillar: in control mode, tee the agent's terminal output into a VT
    // screen so the platform can fetch a rendered snapshot via `__screen__`.
    var render: nether.Render = undefined;
    if (control_on) {
        const rows: u16 = @intCast(std.math.clamp(confGetInt("screen_rows", 24), 1, 200));
        const cols: u16 = @intCast(std.math.clamp(confGetInt("screen_cols", 80), 1, 400));
        render = try nether.Render.init(allocator, rows, cols);
        agent_ctx.render = &render;
    }
    defer if (control_on) render.deinit();
    if (vsock_on) {
        const vs = try allocator.create(nether.Vsock);
        vs.* = .{ .guest_cid = 3 };
        vs.on_event = if (agent_mode) agentEvent else vsockEcho;
        vs.on_event_ctx = if (agent_mode) @as(*anyopaque, &agent_ctx) else @as(*anyopaque, vs);
        vs_engine = vs;
        vsdev = .{ .engine = vs };
        vs_dev = nether.virtio.Device.init(vsdev.backend(), gmem);
        vs_intx = .{ .intid = armPciIntxIntid(3) };
        vs_dev.intx_ptr = &vs_intx;
        vs_dev.intx_fn = IntxLine.set;
        vs_dev.msi_ptr = &vs_dev;
        vs_dev.msi_fn = armSendMsi;
        try pci_host.addFunction(vs_dev.function(3, 0));
        vsdev.attach(&vs_dev);
        _ = vsdev.hostListen(if (agent_mode) 5000 else 1234); // 5000 = agent control port
    }

    // Function 0:4.0 - virtio-net behind the in-VMM user-mode network stack
    // (opt-in via a `nether-net` marker), so the guest gets a configured eth0 with
    // no host tap/bridge/root: guest TX frames go to slirp, replies come back via
    // pushRx. Address plan 10.0.2.0/24 (guest .15, gateway .2, DNS .3).
    var net_be: nether.VirtioNet = undefined;
    var net_dev: nether.virtio.Device = undefined;
    var net_intx: IntxLine = undefined;
    var slirp_stack: nether.Slirp = undefined;
    const net_on = modeOn("net", "nether-net");
    if (net_on) {
        net_be = .{};
        net_dev = nether.virtio.Device.init(net_be.backend(), gmem);
        net_intx = .{ .intid = armPciIntxIntid(4) };
        net_dev.intx_ptr = &net_intx;
        net_dev.intx_fn = IntxLine.set;
        net_dev.msi_ptr = &net_dev;
        net_dev.msi_fn = armSendMsi;
        try pci_host.addFunction(net_dev.function(4, 0));
        net_be.attach(&net_dev);
        slirp_stack = .{};
        // Egress firewall (govern): default-deny private/loopback/link-local/metadata.
        // net_open=1 disables it; net_allow / net_block add CIDR exceptions.
        if (confBool("net_open")) slirp_stack.fw_enabled = false;
        var fw_allow: [1024]u8 = undefined;
        if (confGet("net_allow", &fw_allow)) |v| {
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |c| {
                const t = std.mem.trim(u8, c, " \t");
                if (t.len > 0 and !slirp_stack.addAllow(t)) std.debug.print("[nether] net_allow: bad/full rule '{s}'\n", .{t});
            }
        }
        var fw_block: [1024]u8 = undefined;
        if (confGet("net_block", &fw_block)) |v| {
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |c| {
                const t = std.mem.trim(u8, c, " \t");
                if (t.len > 0 and !slirp_stack.addBlock(t)) std.debug.print("[nether] net_block: bad/full rule '{s}'\n", .{t});
            }
        }
        // Download bandwidth cap (govern): net_rate_kbps kilobits/sec, 0 = unlimited.
        const rate_kbps = confGetInt("net_rate_kbps", 0);
        if (rate_kbps > 0) slirp_stack.setRateKbps(rate_kbps);
        slirp_stack.out_fn = slirpToNet;
        slirp_stack.out_ctx = &net_be;
        net_be.on_tx = netToSlirp;
        net_be.on_tx_ctx = &slirp_stack;
        meter.net = &slirp_stack; // expose NAT egress/ingress bytes via __stats__
        slirp_stack.journal = &journal; // mirror egress flows into the event timeline
        // Host thread: poll NAT sockets and inject replies back into the guest.
        if (std.Thread.spawn(.{}, slirpPollLoop, .{&slirp_stack})) |t| t.detach() else |_| {}
    }

    // virtio-gpu (render pillar): a framebuffer the guest can draw into and the host
    // can capture via __frame__. Opt-in (gpu=1); size via gpu_width/gpu_height.
    var gpu_be: nether.VirtioGpu = undefined;
    var gpu_dev: nether.virtio.Device = undefined;
    var gpu_intx: IntxLine = undefined;
    const gpu_on = modeOn("gpu", "nether-gpu");
    if (gpu_on) {
        gpu_be = .{
            .width = @intCast(std.math.clamp(confGetInt("gpu_width", 1024), 64, 4096)),
            .height = @intCast(std.math.clamp(confGetInt("gpu_height", 768), 64, 4096)),
        };
        gpu_dev = nether.virtio.Device.init(gpu_be.backend(), gmem);
        gpu_intx = .{ .intid = armPciIntxIntid(5) };
        gpu_dev.intx_ptr = &gpu_intx;
        gpu_dev.intx_fn = IntxLine.set;
        gpu_dev.msi_ptr = &gpu_dev;
        gpu_dev.msi_fn = armSendMsi;
        try pci_host.addFunction(gpu_dev.function(5, 0));
        gpu_be.attach(&gpu_dev);
    }

    // One dispatcher over the 64-bit window routes to each function's live BAR.
    var dev_buf: [5]*nether.virtio.Device = undefined;
    var ndev: usize = 0;
    dev_buf[ndev] = &con_dev;
    ndev += 1;
    dev_buf[ndev] = &blk_dev;
    ndev += 1;
    if (vsock_on) {
        dev_buf[ndev] = &vs_dev;
        ndev += 1;
    }
    if (net_on) {
        dev_buf[ndev] = &net_dev;
        ndev += 1;
    }
    if (gpu_on) {
        dev_buf[ndev] = &gpu_dev;
        ndev += 1;
    }
    var bar_win = PciBarWindow{ .devs = dev_buf[0..ndev] };
    try bus.addMmio(bar_win.device());
    try bus.addMmio(pci_host.mmioDevice()); // ECAM config space
    if (gpu_on) std.debug.print("[nether] virtio-gpu: {d}x{d} framebuffer (PCI 0:5.0); capture via __frame__\n", .{ gpu_be.width, gpu_be.height });
    if (vsock_on) std.debug.print("[nether] virtio-vsock: guest CID 3, host echo on port 1234 (PCI 0:3.0)\n", .{});
    if (net_on) std.debug.print("[nether] virtio-net: user-mode net 10.0.2.15/24 gw 10.0.2.2 (PCI 0:4.0); egress firewall {s} (allow={d} block={d}); rate {d} kbps\n", .{ if (slirp_stack.fw_enabled) "on" else "OFF", slirp_stack.allow_n, slirp_stack.block_n, slirp_stack.rate_bps * 8 / 1000 });

    try vcpu.setAarch64Entry(ARM_RAM_BASE, ARM_RAM_BASE + ARM_DTB_OFF); // PC=kernel, X0=DTB

    // Control plane: in nether-control mode a Unix-domain socket drives the agent
    // (the platform attaches without owning this process's stdio). A pipe carries
    // the agent's replies from the recv handler to the relay thread.
    var ctl_pipe: [2]c_int = undefined;
    var ctl_ctx: ControlCtx = undefined;
    if (control_on) {
        if (libc.pipe(&ctl_pipe) == 0) {
            agent_ctx.pipe_w = ctl_pipe[1];
            ctl_ctx = .{ .vsdev = &vsdev, .agent = &agent_ctx, .meter = &meter, .path = ctl_path, .pipe_r = ctl_pipe[0], .allocator = allocator, .power = &power, .handles = handles[0..num_cpus], .num_cpus = num_cpus, .gpu = if (gpu_on) &gpu_be else null, .journal = &journal };
            if (std.Thread.spawn(.{}, controlListener, .{&ctl_ctx})) |t| t.detach() else |_| {}
            if (std.Thread.spawn(.{}, controlRelay, .{&ctl_ctx})) |t| t.detach() else |_| {}
        } else std.debug.print("[control] pipe() failed; control socket disabled\n", .{});
    }

    // Host stdin: in agent-REPL mode it drives the guest agent (stdin -> sandbox
    // exec -> stdout). Otherwise (interactive or control mode) it feeds the PL011
    // RX for a guest shell; control mode drives the agent over the Unix socket.
    var agent_stdin = AgentStdinCtx{ .vsdev = &vsdev, .agent = &agent_ctx };
    const saved_termios = if (agent_repl) null else armEnableRawMode();
    defer if (saved_termios) |s| armRestoreTermios(s);
    if (agent_repl) {
        if (std.Thread.spawn(.{}, agentStdinPump, .{&agent_stdin})) |t| t.detach() else |_| {}
    } else if (std.Thread.spawn(.{}, armStdinPump, .{&uart})) |t| {
        t.detach();
    } else |err| {
        std.debug.print("[nether] stdin thread failed: {s}; console is output-only\n", .{@errorName(err)});
    }

    // Snapshot/restore demo (opt-in via a `nether-snapshot` marker): orchestrator
    // thread captures and later restores the whole machine while the guest runs.
    var snap_ctx = SnapCtx{
        .allocator = allocator,
        .ram = ram,
        .handles = handles[0..num_cpus],
        .num_cpus = num_cpus,
        .snap = &snapctl,
        .con_dev = &con_dev,
        .blk_dev = &blk_dev,
        .blk_disk = blk.disk,
        .uart = &uart,
        .save = modeOn("snapshot_save", "nether-snapshot-save"),
    };
    if (modeOn("snapshot", "nether-snapshot") or snap_ctx.save) {
        if (std.Thread.spawn(.{}, macSnapshotter, .{&snap_ctx})) |t| t.detach() else |_| {}
        std.debug.print("[nether] snapshot {s} armed\n", .{if (snap_ctx.save) "save-to-file" else "rewind demo"});
    }

    // Runtime budget (govern): a watchdog stops the sandbox after max_runtime_s of
    // wall clock - a hard cap on cost/runaway for untrusted agents (the time axis,
    // alongside the firewall/bandwidth/sizing controls). 0 = unlimited.
    var wd_ctx: WatchdogCtx = undefined;
    const max_runtime_s = confGetInt("max_runtime_s", 0);
    if (max_runtime_s > 0) {
        wd_ctx = .{ .power = &power, .handles = handles[0..num_cpus], .num_cpus = num_cpus, .start_ms = nowMs(), .budget_ms = @intCast(max_runtime_s * 1000) };
        if (std.Thread.spawn(.{}, macWatchdog, .{&wd_ctx})) |t| t.detach() else |_| {}
        std.debug.print("[nether] runtime budget armed: {d}s\n", .{max_runtime_s});
    }

    std.debug.print("[nether] booting arm64 Image: {d} cpus, kernel {d}B, initramfs {d}B, DTB {d}B, GIC d=0x{x} rbase=0x{x} rsize=0x{x}\n", .{ num_cpus, kernel.len, if (initramfs) |fs| fs.len else 0, dtb_len, vm.hv.gicd_size, gicr_base, vm.hv.gicr_size });
    const reason = vcpu.runSmp(&bus, &power, &smpc, &snapctl) catch |err| {
        std.debug.print("\n[nether] vcpu stopped: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("\n[nether] guest {s}.\n", .{@tagName(reason)});
}

/// Runtime-budget watchdog context: a deadline plus what it needs to stop the VM.
const WatchdogCtx = struct {
    power: *nether.Power,
    handles: []const u64,
    num_cpus: u32,
    start_ms: i64, // matches nowMs()
    budget_ms: i64,
};

/// Stop the sandbox once its wall-clock budget elapses. Uses the same path a guest
/// PSCI poweroff takes: request a shutdown, then force the vCPUs out of
/// `hv_vcpu_run` so the run loop observes the action and returns `.shutdown`
/// (cpu0's return unwinds macBootLinux and the process exits). Re-fires the exit a
/// few times in case a vCPU is between runs or parked in WFI inside HVF.
fn macWatchdog(ctx: *WatchdogCtx) void {
    while (nowMs() - ctx.start_ms < ctx.budget_ms) _ = usleep(200_000); // ~5 Hz
    std.debug.print("\n[nether] runtime budget ({d}s) reached; stopping sandbox\n", .{@divTrunc(ctx.budget_ms, 1000)});
    stopSandbox(ctx.power, ctx.handles, ctx.num_cpus);
}

/// Per-secondary-core thread context. The vCPU is created inside the thread (HVF
/// binds a vCPU to its creating thread), so only the id and the shared VM/bus/
/// power/smp handles cross the boundary.
const SmpCtx = struct {
    vm: *nether.Vm,
    id: u32,
    cpu: *nether.smp.Cpu,
    bus: *nether.Bus,
    power: *nether.Power,
    smpc: *nether.smp.Smp,
    created: *std.atomic.Value(u32),
    handles: [*]u64, // each secondary records its vCPU handle for snapshot quiesce
    snap: *anyopaque, // *hvf_backend.SnapCtl (typed in the mac-only path)
};

/// A secondary core: create its vCPU (establishing its GIC redistributor), report
/// readiness, then park until PSCI CPU_ON gives it an entry point and run from
/// there. x0 = the PSCI context_id, per the boot protocol.
fn macSecondaryCpu(ctx: *SmpCtx) void {
    const hvfb = @import("hvf_backend.zig");
    var vcpu = ctx.vm.createVcpu(ctx.id) catch {
        _ = ctx.created.fetchAdd(1, .release); // count anyway so the boot core proceeds
        return;
    };
    defer vcpu.deinit();
    ctx.handles[ctx.id] = vcpu.handle; // for hv_vcpus_exit during a snapshot
    _ = ctx.created.fetchAdd(1, .release);
    while (!ctx.cpu.started.load(.acquire)) {
        if (ctx.power.action != null) return; // shutdown before we were ever turned on
        _ = usleep(200);
    }
    vcpu.setAarch64Entry(ctx.cpu.entry, ctx.cpu.context) catch return;
    const sn: *hvfb.SnapCtl = @ptrCast(@alignCast(ctx.snap));
    _ = vcpu.runSmp(ctx.bus, ctx.power, ctx.smpc, sn) catch {};
}

/// First light under Apple HVF: a tiny aarch64 blob writes a message to the PL011
/// (MMIO, dispatched through the same Bus the x86 path uses) and powers off via
/// PSCI. Proves hv_vm_create/map, hv_vcpu_run, and the data-abort/HVC decode.
fn macBlobDemo(allocator: std.mem.Allocator) !void {
    const hvf = @import("hvf.zig");

    var vm = try nether.Vm.init(allocator);
    defer vm.deinit();
    const ram = try vm.addMemory(0, ARM_RAM_BASE, 2 * nether.memmap.mib);

    var power = nether.Power{};
    var uart = nether.Pl011{};
    uart.out_fn = uartOut;
    uart.out_ctx = &uart;
    var bus = nether.Bus{};
    try bus.addMmio(uart.device(ARM_UART_BASE));

    const blob = comptime buildArmBlob(arm_message);
    @memcpy(ram[0..blob.len], &blob);
    hvf.sys_icache_invalidate(ram.ptr, blob.len);

    var vcpu = try vm.createVcpu(0);
    defer vcpu.deinit();
    try vcpu.setAarch64Entry(ARM_RAM_BASE, 0);

    const reason = vcpu.run(&bus, &power) catch |err| {
        std.debug.print("[nether] vcpu stopped: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("\n[nether] guest {s}.\n", .{@tagName(reason)});
}

// aarch64 instruction encoders (just what the blob needs).
fn movzW(rd: u32, imm16: u32) u32 {
    return 0x52800000 | (imm16 << 5) | rd; // MOVZ Wd, #imm16
}
fn movkW(rd: u32, imm16: u32, hw: u32) u32 {
    return 0x72800000 | (hw << 21) | (imm16 << 5) | rd; // MOVK Wd, #imm16, LSL #(16*hw)
}
fn movzX(rd: u32, imm16: u32, hw: u32) u32 {
    return 0xD2800000 | (hw << 21) | (imm16 << 5) | rd; // MOVZ Xd, #imm16, LSL #(16*hw)
}
fn strb(rt: u32, rn: u32) u32 {
    return 0x39000000 | (rn << 5) | rt; // STRB Wt, [Xn]
}

/// Comptime-assemble: load the UART base into x1, store each message byte to its
/// data register, then PSCI SYSTEM_OFF via `hvc #0`. MOVZ immediates are
/// absolute, so the blob is position-independent (it runs from ARM_RAM_BASE).
fn buildArmBlob(comptime msg: []const u8) [(2 * msg.len + 5) * 4]u8 {
    var buf: [(2 * msg.len + 5) * 4]u8 = undefined;
    var p: usize = 0;
    const emit = struct {
        fn one(b: []u8, pos: *usize, instr: u32) void {
            std.mem.writeInt(u32, b[pos.*..][0..4], instr, .little);
            pos.* += 4;
        }
    }.one;
    emit(&buf, &p, movzX(1, 0x0900, 1)); // x1 = 0x0900_0000 (UART base = PL011 DR)
    for (msg) |c| {
        emit(&buf, &p, movzW(0, c)); // w0 = char
        emit(&buf, &p, strb(0, 1)); // strb w0, [x1]
    }
    emit(&buf, &p, movzW(0, 0x0008)); // w0 = 0x8400_0008 (PSCI SYSTEM_OFF):
    emit(&buf, &p, movkW(0, 0x8400, 1)); //   low half then high half
    emit(&buf, &p, 0xD4000002); // hvc #0
    emit(&buf, &p, 0x14000000); // b . (fallback if SYSTEM_OFF is missed)
    return buf;
}
