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

/// Host-side agent control. The sandbox becomes a REPL: host stdin lines are sent
/// as commands to the in-guest agent (tools/agent.c) over vsock, and the command
/// output the agent streams back is written to host stdout. The guest agent
/// connects on boot; we record its connection id so the stdin pump can drive it.
const AgentCtx = struct {
    conn_id: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),
    /// Control-socket mode: agent replies are written raw to this pipe for the
    /// relay thread to forward to the connected control client. -1 = REPL mode
    /// (parse and print to stdout instead).
    pipe_w: i32 = -1,
    parsing_exit: bool = false, // mid-parse of the 0x1e<code>\n trailer
    exit_buf: [16]u8 = undefined,
    exit_len: usize = 0,

    /// Parse the agent's framed reply stream: raw output up to 0x1e, then the
    /// command's exit code, printed as a `[exit N]` line.
    fn onRecv(a: *AgentCtx, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            if (a.parsing_exit) {
                if (bytes[i] == '\n') {
                    std.debug.print("[exit {s}]\n", .{a.exit_buf[0..a.exit_len]});
                    a.parsing_exit = false;
                    a.exit_len = 0;
                } else if (a.exit_len < a.exit_buf.len) {
                    a.exit_buf[a.exit_len] = bytes[i];
                    a.exit_len += 1;
                }
                i += 1;
            } else {
                const start = i;
                while (i < bytes.len and bytes[i] != 0x1e) i += 1;
                if (i > start) _ = std.c.write(1, bytes[start..].ptr, i - start);
                if (i < bytes.len) { // hit the 0x1e separator
                    a.parsing_exit = true;
                    i += 1;
                }
            }
        }
    }
};
fn agentEvent(ctx: *anyopaque, ev: nether.vsock.Event) void {
    const a: *AgentCtx = @ptrCast(@alignCast(ctx));
    switch (ev) {
        .accept => |id| {
            a.conn_id.store(@intCast(id), .release);
            std.debug.print("[agent] guest agent connected; type commands (they run in the sandbox)\n", .{});
        },
        .recv => |r| if (a.pipe_w >= 0) {
            _ = libc.write(a.pipe_w, r.bytes.ptr, r.bytes.len); // -> relay -> control client
        } else a.onRecv(r.bytes),
        .shutdown, .reset => a.conn_id.store(-1, .release),
        else => {},
    }
}

/// Control plane: a Unix-domain socket the platform connects to in order to drive
/// the in-guest agent without owning this process's stdio. One control client at
/// a time: its command lines are forwarded to the agent over vsock, and the
/// agent's framed replies are relayed back. The framing (output + 0x1e<exit>\n) is
/// the agent's, so the client parses results just as a stdio driver would.
const ControlCtx = struct {
    vsdev: *nether.VsockDev,
    agent: *AgentCtx,
    meter: *Metering,
    path: [*:0]const u8,
    pipe_r: i32,
    client: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),
};

/// Send one command line to the guest agent (waiting for it to connect), counting
/// it for metering. The `__stats__` line is intercepted here and answered by the
/// host without touching the guest.
fn controlCommand(ctx: *ControlCtx, c: c_int, line: []const u8) void {
    if (std.mem.eql(u8, line, "__stats__\n") or std.mem.eql(u8, line, "__stats__")) {
        var rep: [512]u8 = undefined;
        const n = ctx.meter.report(&rep);
        _ = libc.write(c, rep[0..n].ptr, n);
        _ = ctx.meter.bytes_out.fetchAdd(n, .release);
        return;
    }
    var id = ctx.agent.conn_id.load(.acquire);
    while (id < 0) {
        _ = usleep(50_000);
        id = ctx.agent.conn_id.load(.acquire);
    }
    _ = ctx.vsdev.hostSend(@intCast(id), line);
    _ = ctx.meter.commands.fetchAdd(1, .release);
    _ = ctx.meter.bytes_in.fetchAdd(line.len, .release);
}

fn controlListener(ctx: *ControlCtx) void {
    const fd = libc.socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        std.debug.print("[control] socket() failed\n", .{});
        return;
    }
    _ = libc.unlink(ctx.path);
    var addr = SockaddrUn{};
    const p = std.mem.span(ctx.path);
    @memcpy(addr.path[0..p.len], p);
    addr.len = @intCast(2 + p.len + 1);
    if (libc.bind(fd, &addr, addr.len) < 0 or libc.listen(fd, 4) < 0) {
        std.debug.print("[control] bind/listen failed on {s}\n", .{ctx.path});
        return;
    }
    std.debug.print("[control] listening on {s}\n", .{ctx.path});
    while (true) {
        const c = libc.accept(fd, null, null);
        if (c < 0) continue;
        ctx.client.store(c, .release);
        // Line-buffer the client stream so `__stats__` can be intercepted and each
        // command metered; everything else is forwarded verbatim to the agent.
        var buf: [4096]u8 = undefined;
        var len: usize = 0;
        while (true) {
            const r = libc.read(c, buf[len..].ptr, buf.len - len);
            if (r <= 0) break;
            len += @intCast(r);
            var start: usize = 0;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (buf[i] == '\n') {
                    controlCommand(ctx, c, buf[start .. i + 1]);
                    start = i + 1;
                }
            }
            if (start > 0) {
                std.mem.copyForwards(u8, buf[0 .. len - start], buf[start..len]);
                len -= start;
            }
            if (len == buf.len) len = 0; // overlong line: drop
        }
        ctx.client.store(-1, .release);
        _ = libc.close(c);
    }
}

/// Relay the guest agent's reply stream (from the recv pipe) to the current
/// control client.
fn controlRelay(ctx: *ControlCtx) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = libc.read(ctx.pipe_r, &buf, buf.len);
        if (n <= 0) return;
        const c = ctx.client.load(.acquire);
        if (c >= 0) {
            _ = libc.write(c, buf[0..@intCast(n)].ptr, @intCast(n));
            _ = ctx.meter.bytes_out.fetchAdd(@intCast(n), .release);
        }
    }
}

/// I/O thread (agent mode): forward host stdin to the guest agent over vsock.
fn agentStdinPump(ctx: *AgentStdinCtx) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = libc.read(0, &buf, buf.len);
        if (n <= 0) return;
        var id = ctx.agent.conn_id.load(.acquire);
        while (id < 0) { // wait until the guest agent has connected
            _ = usleep(50_000);
            id = ctx.agent.conn_id.load(.acquire);
        }
        _ = ctx.vsdev.hostSend(@intCast(id), buf[0..@intCast(n)]);
    }
}
const AgentStdinCtx = struct { vsdev: *nether.VsockDev, agent: *AgentCtx };

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

// Guest layout for the Linux boot: kernel at the RAM base (Image text_offset 0),
// the DTB at +128 MiB, and the initramfs at +192 MiB, all clear of the ~35 MiB
// kernel image.
const ARM_RAM_SIZE: usize = 512 * nether.memmap.mib; // default; nether.conf ram_mb overrides
const ARM_DTB_OFF: u64 = 0x0800_0000;
const ARM_INITRD_OFF: u64 = 0x0C00_0000;
/// Default and ceiling vCPU counts. Secondaries come online via PSCI CPU_ON (see
/// smp.zig); each vCPU runs on its own thread (an HVF vCPU is bound to its
/// creating thread). The actual count is from nether.conf, clamped to MAX.
const ARM_NUM_CPUS: u32 = 4;
const ARM_MAX_CPUS: u32 = 8; // == hvf_backend.MAX_SNAP_CPUS; sizes the SMP arrays

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
    // Control socket path from nether.conf (per-sandbox), else the default. A
    // configured path also enables control mode (no marker needed).
    var sock_path_buf: [256]u8 = undefined;
    const have_sock_conf = confGet("control_socket", &sock_path_buf) != null;
    const ctl_path: [*:0]const u8 = if (have_sock_conf) @ptrCast(&sock_path_buf) else "/tmp/nether.sock";
    const control_on = modeOn("control", "nether-control") or have_sock_conf;
    const agent_repl = modeOn("agent", "nether-agent") and !control_on;
    const agent_mode = control_on or agent_repl; // both drive the agent via agentEvent
    const vsock_on = modeOn("vsock", "nether-vsock") or agent_mode;
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
        slirp_stack.out_fn = slirpToNet;
        slirp_stack.out_ctx = &net_be;
        net_be.on_tx = netToSlirp;
        net_be.on_tx_ctx = &slirp_stack;
        meter.net = &slirp_stack; // expose NAT egress/ingress bytes via __stats__
        // Host thread: poll NAT sockets and inject replies back into the guest.
        if (std.Thread.spawn(.{}, slirpPollLoop, .{&slirp_stack})) |t| t.detach() else |_| {}
    }

    // One dispatcher over the 64-bit window routes to each function's live BAR.
    var dev_buf: [4]*nether.virtio.Device = undefined;
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
    var bar_win = PciBarWindow{ .devs = dev_buf[0..ndev] };
    try bus.addMmio(bar_win.device());
    try bus.addMmio(pci_host.mmioDevice()); // ECAM config space
    if (vsock_on) std.debug.print("[nether] virtio-vsock: guest CID 3, host echo on port 1234 (PCI 0:3.0)\n", .{});
    if (net_on) std.debug.print("[nether] virtio-net: user-mode net 10.0.2.15/24 gw 10.0.2.2 (PCI 0:4.0)\n", .{});

    try vcpu.setAarch64Entry(ARM_RAM_BASE, ARM_RAM_BASE + ARM_DTB_OFF); // PC=kernel, X0=DTB

    // Control plane: in nether-control mode a Unix-domain socket drives the agent
    // (the platform attaches without owning this process's stdio). A pipe carries
    // the agent's replies from the recv handler to the relay thread.
    var ctl_pipe: [2]c_int = undefined;
    var ctl_ctx: ControlCtx = undefined;
    if (control_on) {
        if (libc.pipe(&ctl_pipe) == 0) {
            agent_ctx.pipe_w = ctl_pipe[1];
            ctl_ctx = .{ .vsdev = &vsdev, .agent = &agent_ctx, .meter = &meter, .path = ctl_path, .pipe_r = ctl_pipe[0] };
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

    std.debug.print("[nether] booting arm64 Image: {d} cpus, kernel {d}B, initramfs {d}B, DTB {d}B, GIC d=0x{x} rbase=0x{x} rsize=0x{x}\n", .{ num_cpus, kernel.len, if (initramfs) |fs| fs.len else 0, dtb_len, vm.hv.gicd_size, gicr_base, vm.hv.gicr_size });
    const reason = vcpu.runSmp(&bus, &power, &smpc, &snapctl) catch |err| {
        std.debug.print("\n[nether] vcpu stopped: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("\n[nether] guest {s}.\n", .{@tagName(reason)});
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

/// Context for the snapshot orchestrator thread.
const SnapCtx = struct {
    allocator: std.mem.Allocator,
    ram: []u8,
    handles: []const u64,
    num_cpus: u32,
    snap: *anyopaque, // *hvf_backend.SnapCtl
    con_dev: *nether.virtio.Device,
    blk_dev: *nether.virtio.Device,
    blk_disk: []u8,
    uart: *nether.Pl011,
    save: bool = false, // true: serialize to nether.snap (fork source); false: in-place rewind
};

fn countDiff(a: []const u8, b: []const u8) u64 {
    var n: u64 = 0;
    const len = @min(a.len, b.len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (a[i] != b[i]) n += 1;
    }
    return n;
}

/// Force all vCPUs out of the guest and wait until each has parked at the snapshot
/// rendezvous (self-captured or self-restored its own context).
fn quiesce(sn: anytype, handles: []const u64, n: u32, phase: u8) void {
    const hvf = @import("hvf.zig");
    sn.parked.store(0, .release);
    sn.phase.store(phase, .release);
    while (sn.parked.load(.acquire) < n) {
        _ = hvf.hv_vcpus_exit(handles.ptr, n); // re-fire; catches a vCPU not yet back in run
        _ = usleep(2000);
    }
}

/// Read 8 bytes from guest physical address `pa` via the host RAM mapping.
fn readGuestU64(ram: []const u8, pa: u64) ?u64 {
    if (pa < ARM_RAM_BASE or pa + 8 > ARM_RAM_BASE + ram.len) return null;
    const off: usize = @intCast(pa - ARM_RAM_BASE);
    return std.mem.readInt(u64, ram[off..][0..8], .little);
}

/// Translate a guest kernel VA (TTBR1 space) to a physical address by walking the
/// guest's page tables in RAM. 4 KiB granule, 48-bit VA, 4-level (Linux arm64
/// virt). Returns null on any invalid descriptor or out-of-RAM table.
fn translateKernelVa(ram: []const u8, ttbr1: u64, va: u64) ?u64 {
    var table = ttbr1 & 0x0000_FFFF_FFFF_F000;
    const shifts = [_]u6{ 39, 30, 21, 12 };
    inline for (shifts, 0..) |sh, lvl| {
        const idx = (va >> sh) & 0x1ff;
        const desc = readGuestU64(ram, table + idx * 8) orelse return null;
        if (desc & 1 == 0) return null; // invalid descriptor
        const out = desc & 0x0000_FFFF_FFFF_F000;
        if (lvl == 3) return out | (va & 0xfff); // L3 page
        if (lvl != 0 and desc & 3 == 1) { // L1/L2 block
            const bsize = @as(u64, 1) << sh;
            return (out & ~(bsize - 1)) | (va & (bsize - 1));
        }
        table = out; // table descriptor; descend
    }
    return null;
}

/// Read the guest instruction word at kernel VA `va` (or null if unmapped).
fn readGuestInsn(ram: []const u8, ttbr1: u64, va: u64) ?u32 {
    const pa = translateKernelVa(ram, ttbr1, va) orelse return null;
    if (pa < ARM_RAM_BASE or pa + 4 > ARM_RAM_BASE + ram.len) return null;
    const off: usize = @intCast(pa - ARM_RAM_BASE);
    return std.mem.readInt(u32, ram[off..][0..4], .little);
}

const WFI_INSN: u32 = 0xd503_207f;
// Comptime index of TTBR1_EL1 within the snapshot sys-reg order.
const TTBR1_SNAP_IDX = blk: {
    for (@import("hvf.zig").SNAPSHOT_SYS_REGS, 0..) |r, i| if (r == 0xc101) break :blk i;
    @compileError("TTBR1_EL1 missing from SNAPSHOT_SYS_REGS");
};

/// Quiesce for a CONSISTENT SMP capture. Forcing vCPUs out at arbitrary PCs can
/// freeze a CPU mid-update of a shared kernel structure (the hrtimer rbtree),
/// which oopses on restore. Here we force-quiesce, then verify every vCPU was
/// caught at a WFI instruction (its idle loop: holding no locks, not mid-update).
/// If any wasn't, we resume briefly and retry, so an idle guest converges on an
/// all-idle capture. A busy guest that never converges within `max_attempts`
/// falls through with the last (best-effort) capture. Returns true if all-idle.
fn quiesceSafe(sn: anytype, ram: []const u8, handles: []const u64, n: u32, max_attempts: u32) bool {
    const hvfb = @import("hvf_backend.zig");
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        quiesce(sn, handles, n, @intFromEnum(hvfb.SnapPhase.quiesce));
        // A CPU caught in its idle loop has just retired the WFI (HVF emulates it
        // and advances PC), so the instruction at PC-4 is the WFI. That means the
        // CPU holds no locks and isn't mid shared-structure update -> safe.
        var idle: u32 = 0;
        for (0..n) |i| {
            const c = &sn.cpu[i];
            if (readGuestInsn(ram, c.sys[TTBR1_SNAP_IDX], c.pc -% 4) == WFI_INSN) idle += 1;
        }
        if (idle == n) return true;
        if (attempt + 1 >= max_attempts) {
            std.debug.print("[nether] quiesceSafe: {d}/{d} vCPUs idle after {d} tries; using best-effort\n", .{ idle, n, attempt + 1 });
            return false;
        }
        // Resume so any CPU caught in the kernel moves on, then re-quiesce.
        sn.phase.store(@intFromEnum(hvfb.SnapPhase.resumed), .release);
        _ = usleep(3000);
    }
}

/// Snapshot/restore demonstration (opt-in via a `nether-snapshot` marker). After
/// the guest is up: quiesce all vCPUs and capture the full machine state (RAM, per
/// vCPU register context, framework GIC state, virtio device state); let the guest
/// run on; then quiesce again and restore everything, rewinding the guest to the
/// snapshot. That the 4-core Linux guest stays healthy afterwards is the proof the
/// captured state is complete and consistent.
fn macSnapshotter(ctx: *SnapCtx) void {
    const hvf = @import("hvf.zig");
    const hvfb = @import("hvf_backend.zig");
    const sn: *hvfb.SnapCtl = @ptrCast(@alignCast(ctx.snap));
    const n = ctx.num_cpus;

    var t: u32 = 0;
    while (t < 200) : (t += 1) _ = usleep(100_000); // ~20s: let the guest reach the shell

    // --- CAPTURE -----------------------------------------------------------
    // Quiesce at a consistent SMP point (all vCPUs caught at their idle WFI) so the
    // captured hrtimer rbtree etc. isn't frozen mid-update (which oopses on restore).
    const safe = quiesceSafe(sn, ctx.ram, ctx.handles, n, 200);
    std.debug.print("[nether] snapshot quiesce: {s}\n", .{if (safe) "all vCPUs idle at WFI (consistent)" else "best-effort (some vCPU not idle)"});
    const cpu_snap = sn.cpu; // vCPUs self-captured into sn.cpu[] while parking
    const ram_snap = ctx.allocator.alloc(u8, ctx.ram.len) catch {
        std.debug.print("[nether] snapshot: out of memory for RAM copy\n", .{});
        return;
    };
    @memcpy(ram_snap, ctx.ram);
    var gicbuf: [128 * 1024]u8 = undefined;
    const giclen = hvfb.gicCaptureState(&gicbuf);
    const con_snap = ctx.con_dev.exportState(); // pointer-free device state
    const blk_snap = ctx.blk_dev.exportState();
    const uart_snap = ctx.uart.exportState();
    const disk_snap = ctx.allocator.alloc(u8, ctx.blk_disk.len) catch return;
    @memcpy(disk_snap, ctx.blk_disk);
    sn.phase.store(@intFromEnum(hvfb.SnapPhase.resumed), .release);
    std.debug.print("\n[nether] SNAPSHOT captured: ram={d}MiB gic={d}B cpus={d}\n", .{ ctx.ram.len / (1024 * 1024), giclen, n });

    // --- SAVE-TO-FILE mode: serialize the fork source and keep running. -----
    if (ctx.save) {
        const ok = writeSnapshotFile("nether.snap", ctx.ram, cpu_snap[0..n], con_snap, blk_snap, uart_snap, gicbuf[0..giclen], disk_snap);
        std.debug.print("[nether] snapshot {s} to nether.snap ({d} MiB + state); guest continues. Run `nether restore` to fork it.\n", .{ if (ok) "written" else "FAILED writing", ctx.ram.len / (1024 * 1024) });
        ctx.allocator.free(ram_snap);
        ctx.allocator.free(disk_snap);
        return;
    }

    // --- REWIND mode: let the guest run, then restore in place. -------------
    t = 0;
    while (t < 40) : (t += 1) _ = usleep(100_000); // ~4s: let the guest run and mutate state
    const advanced = countDiff(ctx.ram, ram_snap);

    sn.cpu = cpu_snap; // load the captured contexts for each vCPU to self-restore
    quiesce(sn, ctx.handles, n, @intFromEnum(hvfb.SnapPhase.restoring));
    @memcpy(ctx.ram, ram_snap);
    if (giclen > 0) _ = hvfb.gicRestoreState(gicbuf[0..giclen]);
    ctx.con_dev.importState(&con_snap);
    ctx.blk_dev.importState(&blk_snap);
    ctx.uart.importState(uart_snap);
    @memcpy(ctx.blk_disk, disk_snap);
    sn.phase.store(@intFromEnum(hvfb.SnapPhase.resumed), .release);
    std.debug.print("\n[nether] RESTORE done: guest had advanced {d} RAM bytes since the snapshot; rewound to it. Guest should still be alive.\n", .{advanced});
    _ = hvf;

    ctx.allocator.free(ram_snap);
    ctx.allocator.free(disk_snap);
}

// --- snapshot file format ---------------------------------------------------
// Header (64 B) then per-vCPU CpuState, the two DeviceStates, the PL011 state,
// GIC bytes, disk bytes, then (page-aligned) RAM. The RAM region is aligned to
// HOST_PAGE so it can be mapped copy-on-write (MAP_PRIVATE) on restore - a fork
// shares the file's pages and only copies what it writes. Same-host/same-build
// only (raw struct layout, native endian).
const SNAP_MAGIC: u32 = 0x4e_53_4e_50; // 'NSNP'
const SNAP_VERSION: u32 = 2;
const HOST_PAGE: usize = 16384; // Apple Silicon page size (mmap offset alignment)

fn writeAll(fd: c_int, buf: []const u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const w = libc.write(fd, buf.ptr + off, buf.len - off);
        if (w <= 0) return false;
        off += @intCast(w);
    }
    return true;
}

fn writeSnapshotFile(
    path: [*:0]const u8,
    ram: []const u8,
    cpus: anytype, // []const hvf_backend.CpuState
    con: anytype, // virtio.Device.DeviceState
    blk: anytype,
    uart: anytype, // Pl011.State
    gic: []const u8,
    disk: []const u8,
) bool {
    const O_WRONLY = 0x0001;
    const O_CREAT = 0x0200;
    const O_TRUNC = 0x0400;
    const fd = libc.open(path, O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
    if (fd < 0) return false;
    defer _ = libc.close(fd);

    // The metadata precedes a page-aligned RAM region (so RAM can be mmap'd COW).
    const meta = 64 + cpus.len * @sizeOf(@TypeOf(cpus[0])) + @sizeOf(@TypeOf(con)) +
        @sizeOf(@TypeOf(blk)) + @sizeOf(@TypeOf(uart)) + gic.len + disk.len;
    const ram_off = std.mem.alignForward(usize, meta, HOST_PAGE);

    var hdr = [_]u8{0} ** 64;
    std.mem.writeInt(u32, hdr[0..4], SNAP_MAGIC, .little);
    std.mem.writeInt(u32, hdr[4..8], SNAP_VERSION, .little);
    std.mem.writeInt(u32, hdr[8..12], @intCast(cpus.len), .little);
    std.mem.writeInt(u64, hdr[16..24], ARM_RAM_BASE, .little);
    std.mem.writeInt(u64, hdr[24..32], ram.len, .little);
    std.mem.writeInt(u64, hdr[32..40], gic.len, .little);
    std.mem.writeInt(u64, hdr[40..48], disk.len, .little);
    std.mem.writeInt(u64, hdr[48..56], ram_off, .little);
    if (!writeAll(fd, &hdr)) return false;
    for (cpus) |*c| if (!writeAll(fd, std.mem.asBytes(c))) return false;
    if (!writeAll(fd, std.mem.asBytes(&con))) return false;
    if (!writeAll(fd, std.mem.asBytes(&blk))) return false;
    if (!writeAll(fd, std.mem.asBytes(&uart))) return false;
    if (!writeAll(fd, gic)) return false;
    if (!writeAll(fd, disk)) return false;
    // Pad to the page-aligned RAM offset, then write RAM.
    var pad = [_]u8{0} ** HOST_PAGE;
    if (ram_off > meta and !writeAll(fd, pad[0 .. ram_off - meta])) return false;
    if (!writeAll(fd, ram)) return false;
    return true;
}

fn readExact(fd: c_int, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const r = libc.read(fd, buf.ptr + off, buf.len - off);
        if (r <= 0) return false;
        off += @intCast(r);
    }
    return true;
}

/// A core in the restore path: create its vCPU (establishing its GIC
/// redistributor), load its captured register context, report ready, then wait
/// for the orchestrator to install global state (RAM/GIC/devices) before running.
const RestoreCtx = struct {
    vm: *nether.Vm,
    id: u32,
    bus: *nether.Bus,
    power: *nether.Power,
    state: *const anyopaque, // *hvf_backend.CpuState
    ready: *std.atomic.Value(u32),
    go: *std.atomic.Value(bool),
};

fn macRestoreCpu(ctx: *RestoreCtx) void {
    const hvfb = @import("hvf_backend.zig");
    var vcpu = ctx.vm.createVcpu(ctx.id) catch {
        _ = ctx.ready.fetchAdd(1, .release);
        return;
    };
    defer vcpu.deinit();
    const st: *const hvfb.CpuState = @ptrCast(@alignCast(ctx.state));
    vcpu.restore(st);
    _ = ctx.ready.fetchAdd(1, .release);
    while (!ctx.go.load(.acquire)) _ = usleep(200);
    _ = vcpu.runSmp(ctx.bus, ctx.power, null, null) catch {};
}

/// Restore a guest from a snapshot file (a cross-process fork): rebuild the VM,
/// map and fill RAM, recreate each vCPU with its captured register context,
/// reinstall the framework GIC state and the virtio device state, and resume.
/// No kernel/DTB load - the snapshot *is* the booted guest.
fn macRestore(allocator: std.mem.Allocator, path: [*:0]const u8) !void {
    const hvf = @import("hvf.zig");
    const hvfb = @import("hvf_backend.zig");

    const fd = libc.open(path, 0, @as(c_int, 0)); // O_RDONLY
    if (fd < 0) {
        std.debug.print("[nether] restore: cannot open {s}\n", .{path});
        return error.OpenFailed;
    }
    defer _ = libc.close(fd);

    var hdr = [_]u8{0} ** 64;
    if (!readExact(fd, &hdr)) return error.BadSnapshot;
    if (std.mem.readInt(u32, hdr[0..4], .little) != SNAP_MAGIC) return error.BadSnapshot;
    const num_cpus = std.mem.readInt(u32, hdr[8..12], .little);
    const ram_size = std.mem.readInt(u64, hdr[24..32], .little);
    const gic_size = std.mem.readInt(u64, hdr[32..40], .little);
    const disk_size = std.mem.readInt(u64, hdr[40..48], .little);
    const ram_off = std.mem.readInt(u64, hdr[48..56], .little);
    if (num_cpus > hvfb.MAX_SNAP_CPUS or ram_size == 0) return error.BadSnapshot;

    var vm = try nether.Vm.init(allocator);
    defer vm.deinit();
    // Map RAM copy-on-write from the snapshot file (at the snapshot's own size):
    // the fork shares the base image's pages and only copies what it writes, so
    // restore is instant (no full read) and forks are memory-cheap.
    const ram = try vm.hv.mapMemoryCow(ARM_RAM_BASE, @intCast(ram_size), fd, ram_off);
    try vm.enableSplitIrqchip(); // create the GIC before vCPUs (state restored below)

    // Read the small metadata sequentially (cpus, con, blk, uart, gic, disk); RAM
    // is mapped above by offset, not read.
    var cpus: [hvfb.MAX_SNAP_CPUS]hvfb.CpuState = undefined;
    var i: u32 = 0;
    while (i < num_cpus) : (i += 1) if (!readExact(fd, std.mem.asBytes(&cpus[i]))) return error.BadSnapshot;
    var con_state: nether.virtio.Device.DeviceState = undefined;
    var blk_state: nether.virtio.Device.DeviceState = undefined;
    var uart_state: nether.Pl011.State = undefined;
    if (!readExact(fd, std.mem.asBytes(&con_state))) return error.BadSnapshot;
    if (!readExact(fd, std.mem.asBytes(&blk_state))) return error.BadSnapshot;
    if (!readExact(fd, std.mem.asBytes(&uart_state))) return error.BadSnapshot;
    const gic = try allocator.alloc(u8, gic_size);
    defer allocator.free(gic);
    if (!readExact(fd, gic)) return error.BadSnapshot;
    if (disk_size > 0) {
        if (!readExact(fd, blk_disk_storage[0..@intCast(disk_size)])) return error.BadSnapshot;
    }
    // No up-front I-cache invalidation: the RAM pages are demand-paged COW from
    // the file (already at the point of unification) and a freshly created vCPU's
    // I-cache is empty, so there is nothing stale to flush - unlike the boot path,
    // which stores the kernel through the host mapping immediately before fetch.
    // This keeps the restore lazy (no 512 MiB page-in).
    _ = hvf;

    // Recreate vCPUs with their captured contexts. cpu0 is this thread; the rest
    // each create/restore on their own thread (HVF binds a vCPU to its creator).
    var vcpu = try vm.createVcpu(0);
    defer vcpu.deinit();
    vcpu.restore(&cpus[0]);

    var power = nether.Power{};
    var bus = nether.Bus{};
    var ready = std.atomic.Value(u32).init(0);
    var go = std.atomic.Value(bool).init(false);
    var rc: [hvfb.MAX_SNAP_CPUS]RestoreCtx = undefined;
    var s: u32 = 1;
    while (s < num_cpus) : (s += 1) {
        rc[s] = .{ .vm = &vm, .id = s, .bus = &bus, .power = &power, .state = &cpus[s], .ready = &ready, .go = &go };
        (std.Thread.spawn(.{}, macRestoreCpu, .{&rc[s]}) catch return).detach();
    }
    while (ready.load(.acquire) < num_cpus - 1) _ = usleep(200); // all redistributors exist

    // Reinstall global state while every vCPU is parked before `go`.
    if (gic_size > 0 and !hvfb.gicRestoreState(gic)) std.debug.print("[nether] restore: gic_set_state failed\n", .{});

    // Rewire devices to this process and import their captured transport state.
    const gmem = nether.virtq.GuestMem{ .bytes = ram, .base = ARM_RAM_BASE };
    var pci_host = nether.PciHost{ .ecam_base = nether.memmap_arm.ecam_base, .ecam_size = nether.memmap_arm.ecam_size };
    var uart = nether.Pl011{};
    uart.out_fn = uartOut;
    uart.out_ctx = &uart;
    uart.irq_fn = armUartIrq;
    uart.irq_ctx = &uart;
    uart.importState(uart_state); // restore IMSC so RX interrupts reach the guest
    try bus.addMmio(uart.device(ARM_UART_BASE));

    var con = nether.VirtioConsole{};
    con.out_fn = consoleOut;
    con.out_ctx = &con;
    var con_dev = nether.virtio.Device.init(con.backend(), gmem);
    con.attach(&con_dev);
    var con_intx = IntxLine{ .intid = armPciIntxIntid(1) };
    con_dev.intx_ptr = &con_intx;
    con_dev.intx_fn = IntxLine.set;
    con_dev.msi_ptr = &con_dev;
    con_dev.msi_fn = armSendMsi;
    con_dev.importState(&con_state);
    try pci_host.addFunction(con_dev.function(1, 0));

    var blk = nether.VirtioBlk{ .disk = blk_disk_storage[0..] };
    var blk_dev = nether.virtio.Device.init(blk.backend(), gmem);
    var blk_intx = IntxLine{ .intid = armPciIntxIntid(2) };
    blk_dev.intx_ptr = &blk_intx;
    blk_dev.intx_fn = IntxLine.set;
    blk_dev.msi_ptr = &blk_dev;
    blk_dev.msi_fn = armSendMsi;
    blk_dev.importState(&blk_state);
    try pci_host.addFunction(blk_dev.function(2, 0));

    var dev_list = [_]*nether.virtio.Device{ &con_dev, &blk_dev };
    var bar_win = PciBarWindow{ .devs = &dev_list };
    try bus.addMmio(bar_win.device());
    try bus.addMmio(pci_host.mmioDevice());

    const saved_termios = armEnableRawMode();
    defer if (saved_termios) |t| armRestoreTermios(t);
    if (std.Thread.spawn(.{}, armStdinPump, .{&uart})) |t| t.detach() else |_| {}

    std.debug.print("[nether] RESTORED from {s}: {d} cpus, {d} MiB RAM, gic {d}B. Resuming the forked guest.\n", .{ path, num_cpus, ram_size / (1024 * 1024), gic_size });
    go.store(true, .release); // release secondaries; run cpu0
    const reason = vcpu.runSmp(&bus, &power, null, null) catch |err| {
        std.debug.print("\n[nether] forked guest stopped: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("\n[nether] forked guest {s}.\n", .{@tagName(reason)});
}

/// Opt-in marker check (macOS libc), mirroring the x86 markerPresent.
fn macMarkerPresent(path: [*:0]const u8) bool {
    const fd = libc.open(path, 0, @as(c_int, 0));
    if (fd < 0) return false;
    _ = libc.close(fd);
    return true;
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
    extern "c" fn write(fd: c_int, buf: [*]const u8, nbyte: usize) isize;
    // Unix-domain control socket + a pipe to relay the guest agent's replies.
    extern "c" fn socket(domain: c_int, ty: c_int, proto: c_int) c_int;
    extern "c" fn bind(fd: c_int, addr: *const SockaddrUn, len: u32) c_int;
    extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
    extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
    extern "c" fn unlink(path: [*:0]const u8) c_int;
    extern "c" fn pipe(fds: *[2]c_int) c_int;
};
extern "c" fn usleep(usec: c_uint) c_int;

const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;
const SockaddrUn = extern struct {
    len: u8 = 0,
    family: u8 = AF_UNIX,
    path: [104]u8 = [_]u8{0} ** 104,
};

/// Read a `key=value` from `nether.conf` in the cwd into `out` (NUL-terminated for
/// socket binds), returning the value or null if the file/key is absent. The
/// platform writes one config per sandbox (e.g. a distinct `control_socket` path)
/// so many sandboxes run on one host. Minimal: `key = value` lines, `#` comments.
fn confGet(key: []const u8, out: []u8) ?[]const u8 {
    const fd = libc.open("nether.conf", 0, @as(c_int, 0));
    if (fd < 0) return null;
    defer _ = libc.close(fd);
    var buf: [4096]u8 = undefined;
    const n = libc.read(fd, &buf, buf.len);
    if (n <= 0) return null;
    var it = std.mem.splitScalar(u8, buf[0..@intCast(n)], '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \t\r");
        if (l.len == 0 or l[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, l[0..eq], " \t"), key)) continue;
        const v = std.mem.trim(u8, l[eq + 1 ..], " \t");
        if (v.len + 1 > out.len) return null;
        @memcpy(out[0..v.len], v);
        out[v.len] = 0; // NUL terminator for [*:0] consumers
        return out[0..v.len];
    }
    return null;
}

/// nether.conf integer value for `key`, or `default` if absent/unparseable.
fn confGetInt(key: []const u8, default: u64) u64 {
    var b: [32]u8 = undefined;
    if (confGet(key, &b)) |v| return std.fmt.parseInt(u64, v, 10) catch default;
    return default;
}

/// nether.conf boolean (`1`/`true`/`yes`) for `key`, false if absent.
fn confBool(key: []const u8) bool {
    var b: [16]u8 = undefined;
    if (confGet(key, &b)) |v| {
        return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "yes");
    }
    return false;
}

/// A mode is on if its config key is set or its (legacy) marker file is present.
fn modeOn(comptime conf_key: []const u8, comptime marker: [*:0]const u8) bool {
    return confBool(conf_key) or macMarkerPresent(marker);
}

// macOS timeval: tv_sec is time_t (i64), tv_usec is suseconds_t (i32).
const timeval = extern struct { sec: i64, usec: i32 };
extern "c" fn gettimeofday(tv: *timeval, tz: ?*anyopaque) c_int;
fn nowMs() i64 {
    var tv: timeval = .{ .sec = 0, .usec = 0 };
    _ = gettimeofday(&tv, null);
    return tv.sec * 1000 + @divTrunc(tv.usec, 1000);
}

/// Per-sandbox resource usage, exposed to the platform (which settles per use)
/// via the `__stats__` control command. Counters are shared across the control
/// threads; the platform reads them to meter compute, RAM, and I/O.
const Metering = struct {
    start_ms: i64 = 0,
    ram_mb: u64 = 0,
    cpus: u32 = 0,
    commands: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    bytes_in: std.atomic.Value(u64) = std.atomic.Value(u64).init(0), // client -> sandbox
    bytes_out: std.atomic.Value(u64) = std.atomic.Value(u64).init(0), // sandbox -> client
    net: ?*nether.Slirp = null, // network NAT, for egress/ingress byte counts

    /// Render a stats report (text + the agent's 0x1e<exit>\n framing) into `buf`.
    fn report(self: *Metering, buf: []u8) usize {
        const net_tx = if (self.net) |s| s.tx_bytes.load(.monotonic) else 0;
        const net_rx = if (self.net) |s| s.rx_bytes.load(.monotonic) else 0;
        return (std.fmt.bufPrint(buf,
            \\nether sandbox stats
            \\uptime_ms={d}
            \\ram_mb={d}
            \\cpus={d}
            \\commands={d}
            \\bytes_in={d}
            \\bytes_out={d}
            \\net_tx_bytes={d}
            \\net_rx_bytes={d}
            \\{c}0
            \\
        , .{
            nowMs() - self.start_ms,
            self.ram_mb,
            self.cpus,
            self.commands.load(.acquire),
            self.bytes_in.load(.acquire),
            self.bytes_out.load(.acquire),
            net_tx,
            net_rx,
            @as(u8, 0x1e),
        }) catch return 0).len;
    }
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

/// virtio-console TX sink: write guest hvc0 output straight to host stdout. The
/// bytes arrive via the virtqueue DMA datapath over the assigned BAR (not the
/// PL011), so seeing them is the end-to-end virtio-pci proof on aarch64.
fn consoleOut(ctx: *anyopaque, bytes: []const u8) void {
    _ = ctx;
    _ = std.c.write(1, bytes.ptr, bytes.len);
}

/// Backing store for the virtio-blk function (1 MiB, in .bss). Sector 0 carries a
/// signature so a guest `head -c /dev/vda` proves the block read datapath end to
/// end. Writes land here in memory (not persisted to a host file).
var blk_disk_storage: [1024 * 1024]u8 = undefined;
fn makeBlkDisk() []u8 {
    @memset(&blk_disk_storage, 0);
    const sig = "NETHER-VIRTIO-BLK-DISK-OK\n";
    @memcpy(blk_disk_storage[0..sig.len], sig);
    return &blk_disk_storage;
}

/// Legacy PCI INTx line for a virtio function (the fallback when the guest has no
/// MSI domain). The DTB interrupt-map routes (slot, INTA) to a GIC SPI via the
/// swizzle pci_intx_spi + ((slot + pin - 1) % 4); each device carries its own
/// IntxLine so the right SPI is asserted. INTx is unused once MSI-X is enabled.
fn armPciIntxIntid(slot: u32) u32 {
    return 32 + nether.memmap_arm.pci_intx_spi + ((slot + 1 - 1) % 4); // pin INTA = 1
}
const IntxLine = struct {
    intid: u32,
    fn set(ctx: *anyopaque, level: bool) void {
        const self: *IntxLine = @ptrCast(@alignCast(ctx));
        const hvf = @import("hvf.zig");
        _ = hvf.hv_gic_set_spi(self.intid, level);
    }
};

/// MSI-X delivery on HVF: forward the guest-programmed message (doorbell address
/// + data = the GICv2m-allocated SPI intid) to the framework GIC, which raises it
/// as if the device had written the doorbell.
fn armSendMsi(ctx: *anyopaque, addr: u64, data: u32) void {
    _ = ctx;
    const hvf = @import("hvf.zig");
    _ = hvf.hv_gic_send_msi(addr, data);
}

/// The PL011's SPI interrupt id: SPIs start at GIC INTID 32, and the DTB places
/// the UART at SPI `uart_spi`.
const ARM_UART_INTID: u32 = 32 + nether.memmap_arm.uart_spi;

/// PL011 interrupt line -> GIC SPI (level). Called from both the vCPU thread
/// (on DR drain) and the stdin thread (on RX); hv_gic_set_spi is global.
fn armUartIrq(ctx: *anyopaque, level: bool) void {
    _ = ctx;
    const hvf = @import("hvf.zig");
    _ = hvf.hv_gic_set_spi(ARM_UART_INTID, level);
}

/// Routes accesses across the whole 64-bit PCI MMIO window to the virtio device
/// whose *live* BAR0 contains the address. The kernel assigns each function's BAR
/// somewhere in the window, so we can't bind fixed sub-regions up front; instead
/// one window-wide dispatcher matches every access against each device's current
/// BAR base. Supports any number of functions on the bus.
const PciBarWindow = struct {
    devs: []const *nether.virtio.Device,

    fn device(self: *PciBarWindow) nether.MmioDevice {
        return .{
            .ptr = self,
            .base = nether.memmap_arm.pci_mmio64_base, // the 64-bit BAR window
            .len = nether.memmap_arm.pci_mmio64_size,
            .read_fn = read,
            .write_fn = write,
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
fn armStdinPump(uart: *nether.Pl011) void {
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
fn armEnableRawMode() ?std.posix.termios {
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

fn armRestoreTermios(saved: std.posix.termios) void {
    std.posix.tcsetattr(0, .NOW, saved) catch {};
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
