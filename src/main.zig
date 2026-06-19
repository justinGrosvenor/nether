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
    // Route host stdin to the serial RX. Non-blocking so the vCPU never stalls
    // polling it; the guest's serial driver picks bytes up via its poll timer.
    const nonblock = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    const fl = linux.fcntl(0, linux.F.GETFL, 0);
    _ = linux.fcntl(0, linux.F.SETFL, fl | @as(usize, nonblock));
    serial.in_fd = 0;
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

    const reason = vcpu.run(&bus, &power, &ioapic) catch |err| {
        std.debug.print("[nether] vcpu stopped: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("\n[nether] guest {s}.\n", .{@tagName(reason)});
}

/// Delivers a virtio MSI-X completion by injecting it through KVM.
const MsiSink = struct {
    vm_fd: i32,
    fn send(ptr: *anyopaque, addr: u64, data: u32) void {
        const self: *MsiSink = @ptrCast(@alignCast(ptr));
        nether.irqchip.signalMsi(self.vm_fd, addr, data) catch {};
    }
};

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
