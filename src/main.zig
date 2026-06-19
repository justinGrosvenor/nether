//! Nether binary: a thin wrapper over the embeddable core. If a `vmlinux` is
//! present in the working directory it is PVH-booted; otherwise a comptime
//! real-mode blob runs as a smoke test. Either way the firmware floor is wired
//! and the vCPU runs until the guest halts or powers off.

const std = @import("std");
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

pub fn main() !void {
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
    var ioapic = nether.IoApic{ .vm_fd = vm.vm_fd };

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
    serial.mirror = &console;
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
    var msi_sink = MsiSink{ .vm_fd = vm.vm_fd };
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

    const reason = vcpu.run(&bus, &power, &ioapic) catch |err| {
        std.debug.print("[nether] vcpu stopped: {s}\n", .{@errorName(err)});
        if (nether.trace.on()) dumpConsole(&console);
        return err;
    };
    std.debug.print("\n[nether] guest {s}.\n", .{@tagName(reason)});
    if (nether.trace.on()) dumpConsole(&console);
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
