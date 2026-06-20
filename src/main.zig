//! Nether binary: a thin wrapper over the embeddable core. If a `vmlinux` is
//! present in the working directory it is PVH-booted; otherwise a comptime
//! real-mode blob runs as a smoke test. Either way the firmware floor is wired
//! and the vCPU runs until the guest halts or powers off.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const nether = @import("root.zig");

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

// Standard arm64 "virt" addresses: RAM at 1 GiB, PL011 UART at 0x0900_0000.
// Power is PSCI (hvc), so there is no MMIO poweroff device.
const ARM_RAM_BASE: u64 = 0x4000_0000;
const ARM_UART_BASE: u64 = 0x0900_0000;

/// macOS/HVF entry: boot an arm64 Linux `Image` from kernels/ if present,
/// otherwise run the first-light blob demo.
fn macMain() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    nether.trace.init();

    if (readFileMac(allocator, "kernels/Image") catch null) |kernel| {
        defer allocator.free(kernel);
        const initramfs = readFileMac(allocator, "kernels/initramfs-virt") catch null;
        defer if (initramfs) |fs| allocator.free(fs);
        try macBootLinux(allocator, kernel, initramfs);
    } else {
        try macBlobDemo(allocator);
    }
}

// Guest layout for the Linux boot: kernel at the RAM base (Image text_offset 0),
// the DTB at +128 MiB, and the initramfs at +192 MiB, all clear of the ~35 MiB
// kernel image.
const ARM_RAM_SIZE: usize = 512 * nether.memmap.mib;
const ARM_DTB_OFF: u64 = 0x0800_0000;
const ARM_INITRD_OFF: u64 = 0x0C00_0000;

/// Boot an arm64 Linux kernel: place the Image, DTB, and initramfs in guest RAM,
/// create the GIC, and enter the kernel with X0 = DTB (the arm64 boot protocol).
fn macBootLinux(allocator: std.mem.Allocator, kernel: []const u8, initramfs: ?[]const u8) !void {
    const hvf = @import("hvf.zig");

    var vm = try nether.Vm.init(allocator);
    defer vm.deinit();
    const ram = try vm.addMemory(0, ARM_RAM_BASE, ARM_RAM_SIZE);
    try vm.enableSplitIrqchip(); // hv_gic_create, before the vCPU

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
        .mem_size = ARM_RAM_SIZE,
        .gicd_size = vm.hv.gicd_size,
        .gicr_size = vm.hv.gicr_size,
        .initrd_start = initrd_start,
        .initrd_end = initrd_end,
    });
    @memcpy(ram[ARM_DTB_OFF..][0..dtb_len], dtb_buf[0..dtb_len]);

    hvf.sys_icache_invalidate(ram.ptr, kernel.len); // host write -> guest I-fetch

    var power = nether.Power{};
    var uart = nether.Pl011{};
    uart.out_fn = uartOut;
    uart.out_ctx = &uart;
    var bus = nether.Bus{};
    try bus.addMmio(uart.device(ARM_UART_BASE));

    var vcpu = try vm.createVcpu(0);
    defer vcpu.deinit();
    try vcpu.setAarch64Entry(ARM_RAM_BASE, ARM_RAM_BASE + ARM_DTB_OFF); // PC=kernel, X0=DTB

    std.debug.print("[nether] booting arm64 Image: kernel {d}B, initramfs {d}B, DTB {d}B, GIC d=0x{x} r=0x{x}\n", .{ kernel.len, if (initramfs) |fs| fs.len else 0, dtb_len, vm.hv.gicd_size, vm.hv.gicr_size });
    const reason = vcpu.run(&bus, &power) catch |err| {
        std.debug.print("\n[nether] vcpu stopped: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("\n[nether] guest {s}.\n", .{@tagName(reason)});
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

/// libc file IO (macOS): std.posix/std.c don't expose these publicly in this Zig,
/// and the new std.Io.Dir reader needs an Io instance; these symbols are linked.
const libc = struct {
    extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, nbyte: usize) isize;
    extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
};

/// Read a whole file (macOS host side). Caller owns the slice.
fn readFileMac(allocator: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const fd = libc.open(path, 0, @as(c_int, 0)); // O_RDONLY
    if (fd < 0) return error.OpenFailed;
    defer _ = libc.close(fd);
    const size_i = libc.lseek(fd, 0, 2); // SEEK_END
    if (size_i <= 0) return error.OpenFailed;
    _ = libc.lseek(fd, 0, 0); // SEEK_SET
    const size: usize = @intCast(size_i);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    var off: usize = 0;
    while (off < size) {
        const n = libc.read(fd, buf.ptr + off, size - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    return buf;
}

/// PL011 TX sink: write one guest byte to host stdout (libc is linked on macOS).
fn uartOut(ctx: *anyopaque, byte: u8) void {
    _ = ctx;
    const b = [1]u8{byte};
    _ = std.c.write(1, &b, 1);
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
