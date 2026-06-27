//! Snapshot / restore host orchestration for the HVF runner. Two paths:
//!   * SAVE/REWIND (`macSnapshotter`): quiesce the running SMP guest at a consistent
//!     point (all vCPUs idle at WFI), capture RAM + per-vCPU regs + GIC + device
//!     state, then either serialize it to `nether.snap` (a fork source) or rewind
//!     the guest to it in place.
//!   * RESTORE (`macRestore`): a cross-process fork - rebuild the VM from a
//!     `nether.snap`, map RAM copy-on-write, recreate the vCPUs with their captured
//!     contexts, reinstall GIC + device state, and resume. The snapshot IS the
//!     booted guest (no kernel/DTB reload).
//! Device wiring on the restore path comes from armdev.zig, shared with the boot
//! path, so this module needs no dependency on main.zig.

const std = @import("std");
const nether = @import("../root.zig");
const hostutil = @import("../common/hostutil.zig");
const armdev = @import("armdev.zig");

const libc = hostutil.libc;
const usleep = hostutil.usleep;
const readExact = hostutil.readExact;
const writeAll = hostutil.writeAll;

const ARM_RAM_BASE = armdev.ARM_RAM_BASE;
const ARM_UART_BASE = armdev.ARM_UART_BASE;
const uartOut = armdev.uartOut;
const consoleOut = armdev.consoleOut;
const armSendMsi = armdev.armSendMsi;
const armUartIrq = armdev.armUartIrq;
const IntxLine = armdev.IntxLine;
const armPciIntxIntid = armdev.armPciIntxIntid;
const PciBarWindow = armdev.PciBarWindow;
const armStdinPump = armdev.armStdinPump;
const armEnableRawMode = armdev.armEnableRawMode;
const armRestoreTermios = armdev.armRestoreTermios;

/// Context for the snapshot orchestrator thread.
pub const SnapCtx = struct {
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
    const hvf = @import("../hvf.zig");
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
    for (@import("../hvf.zig").SNAPSHOT_SYS_REGS, 0..) |r, i| if (r == 0xc101) break :blk i;
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
    const hvfb = @import("../hvf_backend.zig");
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
pub fn macSnapshotter(ctx: *SnapCtx) void {
    const hvf = @import("../hvf.zig");
    const hvfb = @import("../hvf_backend.zig");
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
const SNAP_VERSION: u32 = 3; // bumped: header now carries a struct-layout fingerprint
const HOST_PAGE: usize = 16384; // Apple Silicon page size (mmap offset alignment)
const GIC_STATE_MAX: u64 = 16 * 1024 * 1024; // sane cap for the GIC blob (~126 KiB in practice)

pub const SnapError = error{ BadSnapshot, SnapshotVersionMismatch, SnapshotLayoutMismatch };

/// Validate the 64-byte snapshot header against THIS build before any trailing
/// state is read or RAM is mapped. A snapshot file is operator-supplied and may
/// be stale (written by an older build), corrupt, or truncated; an unvalidated
/// header would otherwise drive a layout-mismatched struct read or an
/// out-of-bounds disk write. Rejects: wrong magic; a version mismatch; a struct
/// layout fingerprint (cpu/device/uart @sizeOf) that differs from this build,
/// which catches silent layout drift even when the version was not bumped; a zero
/// or too-large vCPU count; a zero RAM size; and disk/GIC sizes that would overrun
/// the fixed disk buffer or request an absurd allocation.
fn validateHeader(hdr: *const [64]u8, max_cpus: u32, disk_cap: u64, gic_cap: u64, cpu_sz: u32, dev_sz: u32, uart_sz: u32) SnapError!void {
    if (std.mem.readInt(u32, hdr[0..4], .little) != SNAP_MAGIC) return error.BadSnapshot;
    if (std.mem.readInt(u32, hdr[4..8], .little) != SNAP_VERSION) return error.SnapshotVersionMismatch;
    const num_cpus = std.mem.readInt(u32, hdr[8..12], .little);
    if (num_cpus == 0 or num_cpus > max_cpus) return error.BadSnapshot;
    if (std.mem.readInt(u64, hdr[24..32], .little) == 0) return error.BadSnapshot; // ram_size
    if (std.mem.readInt(u64, hdr[40..48], .little) > disk_cap) return error.BadSnapshot; // disk would overrun
    if (std.mem.readInt(u64, hdr[32..40], .little) > gic_cap) return error.BadSnapshot; // gic absurd
    if (std.mem.readInt(u32, hdr[12..16], .little) != cpu_sz or
        std.mem.readInt(u32, hdr[56..60], .little) != dev_sz or
        std.mem.readInt(u32, hdr[60..64], .little) != uart_sz) return error.SnapshotLayoutMismatch;
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
    // Struct-layout fingerprint (validated on restore): the @sizeOf of each
    // raw-serialized struct, so a layout change is rejected even without a version bump.
    std.mem.writeInt(u32, hdr[12..16], @sizeOf(@TypeOf(cpus[0])), .little);
    std.mem.writeInt(u64, hdr[16..24], ARM_RAM_BASE, .little);
    std.mem.writeInt(u64, hdr[24..32], ram.len, .little);
    std.mem.writeInt(u64, hdr[32..40], gic.len, .little);
    std.mem.writeInt(u64, hdr[40..48], disk.len, .little);
    std.mem.writeInt(u64, hdr[48..56], ram_off, .little);
    std.mem.writeInt(u32, hdr[56..60], @sizeOf(@TypeOf(con)), .little);
    std.mem.writeInt(u32, hdr[60..64], @sizeOf(@TypeOf(uart)), .little);
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
    const hvfb = @import("../hvf_backend.zig");
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
pub fn macRestore(allocator: std.mem.Allocator, path: [*:0]const u8) !void {
    const hvf = @import("../hvf.zig");
    const hvfb = @import("../hvf_backend.zig");

    const fd = libc.open(path, 0, @as(c_int, 0)); // O_RDONLY
    if (fd < 0) {
        std.debug.print("[nether] restore: cannot open {s}\n", .{path});
        return error.OpenFailed;
    }
    defer _ = libc.close(fd);

    var hdr = [_]u8{0} ** 64;
    if (!readExact(fd, &hdr)) return error.BadSnapshot;
    validateHeader(&hdr, hvfb.MAX_SNAP_CPUS, armdev.blk_disk_storage.len, GIC_STATE_MAX, @sizeOf(hvfb.CpuState), @sizeOf(nether.virtio.Device.DeviceState), @sizeOf(nether.Pl011.State)) catch |e| {
        switch (e) {
            error.SnapshotVersionMismatch => std.debug.print("[nether] restore: snapshot is not format v{d} (written by a different build); re-snapshot with this nether\n", .{SNAP_VERSION}),
            error.SnapshotLayoutMismatch => std.debug.print("[nether] restore: snapshot struct layout differs from this build; re-snapshot with this nether\n", .{}),
            error.BadSnapshot => std.debug.print("[nether] restore: snapshot header invalid, corrupt, or truncated\n", .{}),
        }
        return e;
    };
    const num_cpus = std.mem.readInt(u32, hdr[8..12], .little);
    const ram_size = std.mem.readInt(u64, hdr[24..32], .little);
    const gic_size = std.mem.readInt(u64, hdr[32..40], .little);
    const disk_size = std.mem.readInt(u64, hdr[40..48], .little);
    const ram_off = std.mem.readInt(u64, hdr[48..56], .little);

    // The RAM region is mapped copy-on-write by offset (not read), so a file that is
    // too short to contain ram_off + ram_size would not fault here - it would SIGBUS
    // the guest on the first access to the missing tail. Verify the file actually
    // holds the RAM region up front (overflow-safe), then rewind to the metadata.
    const fsize = libc.lseek(fd, 0, 2); // SEEK_END
    _ = libc.lseek(fd, 64, 0); // SEEK_SET back to just after the header
    if (fsize < 0) return error.BadSnapshot;
    const file_size: u64 = @intCast(fsize);
    if (ram_off > file_size or ram_size > file_size - ram_off) {
        std.debug.print("[nether] restore: snapshot truncated (RAM region {d}+{d} exceeds file size {d})\n", .{ ram_off, ram_size, file_size });
        return error.BadSnapshot;
    }

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
        if (!readExact(fd, armdev.blk_disk_storage[0..@intCast(disk_size)])) return error.BadSnapshot;
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

    var blk = nether.VirtioBlk{ .disk = armdev.blk_disk_storage[0..] };
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

// --- tests -----------------------------------------------------------------
const testing = std.testing;

test "snapshot header validation gates version, layout, and oversized sizes" {
    const CPU: u32 = 100;
    const DEV: u32 = 200;
    const UART: u32 = 50;
    const DISK_CAP: u64 = 1024 * 1024;
    const GIC_CAP: u64 = GIC_STATE_MAX;

    // A well-formed header for this "build".
    var hdr = [_]u8{0} ** 64;
    std.mem.writeInt(u32, hdr[0..4], SNAP_MAGIC, .little);
    std.mem.writeInt(u32, hdr[4..8], SNAP_VERSION, .little);
    std.mem.writeInt(u32, hdr[8..12], 4, .little); // num_cpus
    std.mem.writeInt(u32, hdr[12..16], CPU, .little);
    std.mem.writeInt(u64, hdr[24..32], 512 * 1024 * 1024, .little); // ram_size
    std.mem.writeInt(u64, hdr[32..40], 126405, .little); // gic_size
    std.mem.writeInt(u64, hdr[40..48], DISK_CAP, .little); // disk_size == cap (ok)
    std.mem.writeInt(u32, hdr[56..60], DEV, .little);
    std.mem.writeInt(u32, hdr[60..64], UART, .little);
    try validateHeader(&hdr, 8, DISK_CAP, GIC_CAP, CPU, DEV, UART); // accepts a good header

    var bad = hdr;
    std.mem.writeInt(u32, bad[0..4], 0xdead_beef, .little); // wrong magic
    try testing.expectError(error.BadSnapshot, validateHeader(&bad, 8, DISK_CAP, GIC_CAP, CPU, DEV, UART));

    bad = hdr;
    std.mem.writeInt(u32, bad[4..8], SNAP_VERSION + 1, .little); // version mismatch
    try testing.expectError(error.SnapshotVersionMismatch, validateHeader(&bad, 8, DISK_CAP, GIC_CAP, CPU, DEV, UART));

    // Layout drift: this build's cpu struct size differs from the file's fingerprint.
    try testing.expectError(error.SnapshotLayoutMismatch, validateHeader(&hdr, 8, DISK_CAP, GIC_CAP, CPU + 1, DEV, UART));

    bad = hdr;
    std.mem.writeInt(u64, bad[40..48], DISK_CAP + 1, .little); // disk would overrun the buffer
    try testing.expectError(error.BadSnapshot, validateHeader(&bad, 8, DISK_CAP, GIC_CAP, CPU, DEV, UART));

    bad = hdr;
    std.mem.writeInt(u64, bad[32..40], GIC_CAP + 1, .little); // absurd gic size
    try testing.expectError(error.BadSnapshot, validateHeader(&bad, 8, DISK_CAP, GIC_CAP, CPU, DEV, UART));

    bad = hdr;
    std.mem.writeInt(u32, bad[8..12], 9, .little); // too many cpus
    try testing.expectError(error.BadSnapshot, validateHeader(&bad, 8, DISK_CAP, GIC_CAP, CPU, DEV, UART));

    bad = hdr;
    std.mem.writeInt(u64, bad[24..32], 0, .little); // zero ram
    try testing.expectError(error.BadSnapshot, validateHeader(&bad, 8, DISK_CAP, GIC_CAP, CPU, DEV, UART));
}
