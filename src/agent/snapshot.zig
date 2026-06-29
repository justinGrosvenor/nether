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
const conf = @import("../common/conf.zig");
const armdev = @import("armdev.zig");
const control = @import("control.zig");
const platform = @import("platform.zig");

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
    // Control plane, present only when the snapshotted sandbox ran in control/vsock
    // mode. When set, the snapshot also captures the vsock transport + engine state
    // and the agent's connection id, so a forked sandbox resumes a DRIVEABLE control
    // plane (the agent vsock connection survives the fork - no reconnect). All null
    // => a bare console+blk snapshot that restores as before.
    vs_dev: ?*nether.virtio.Device = null,
    vsock: ?*nether.Vsock = null,
    agent: ?*control.AgentCtx = null,
    // virtio-net transport state, present when the snapshotted sandbox ran with net=1.
    // Only the DEVICE (virtqueue) state is captured so the guest's NIC driver resumes
    // coherently; the slirp NAT engine starts fresh on restore (it holds real host
    // sockets a fork cannot inherit, so the guest re-establishes its flows at the TCP
    // level). Null => the fork has no NIC.
    net_dev: ?*nether.virtio.Device = null,
    // Serializes captures: the demo timer and the __snapshot__ control command both
    // drive captureToFile, and two captures must not quiesce at once.
    capturing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Capture full machine state at a consistent SMP safe point and write a fork-source
/// snapshot to `path`, then resume the guest. Host-side orchestration only: the vCPU
/// threads self-park via SnapCtl, so this is safe to call from any thread (the demo
/// timer or the `__snapshot__` control command). The guest stays quiesced for the whole
/// write so the RAM image is consistent (unlike a live copy, which could tear). An
/// in-progress guard rejects a concurrent capture. Returns true on success.
pub fn captureToFile(ctx: *SnapCtx, path: [*:0]const u8) bool {
    const hvfb = @import("../hv/hvf_backend.zig");
    if (ctx.capturing.swap(true, .acq_rel)) {
        std.debug.print("[nether] snapshot: a capture is already in progress\n", .{});
        return false;
    }
    defer ctx.capturing.store(false, .release);
    const sn: *hvfb.SnapCtl = @ptrCast(@alignCast(ctx.snap));
    const n = ctx.num_cpus;

    const safe = quiesceSafe(sn, ctx.ram, ctx.handles, n, 200);
    std.debug.print("[nether] snapshot quiesce: {s}\n", .{if (safe) "all vCPUs idle at WFI (consistent)" else "best-effort (some vCPU not idle)"});
    const cpu_snap = sn.cpu; // vCPUs self-captured into sn.cpu[] while parking
    // Capture the GIC state, sized to the framework's actual state. If this fails (or is
    // implausibly large), ABORT - a snapshot with no GIC state restores a broken interrupt
    // controller and hangs the fork. Resume the guest before bailing so it is not left
    // parked. (Old code silently captured 0 bytes here when the state outgrew a fixed buffer.)
    const gic = hvfb.gicCaptureAlloc(ctx.allocator) orelse {
        std.debug.print("[nether] snapshot: GIC state capture failed; aborting (a fork would have no interrupt controller state)\n", .{});
        sn.phase.store(@intFromEnum(hvfb.SnapPhase.resumed), .release);
        return false;
    };
    defer ctx.allocator.free(gic);
    if (gic.len > GIC_STATE_MAX) {
        std.debug.print("[nether] snapshot: GIC state {d}B exceeds the {d}B cap; aborting\n", .{ gic.len, GIC_STATE_MAX });
        sn.phase.store(@intFromEnum(hvfb.SnapPhase.resumed), .release);
        return false;
    }
    const con_snap = ctx.con_dev.exportState();
    const blk_snap = ctx.blk_dev.exportState();
    const uart_snap = ctx.uart.exportState();
    // Control plane + net device state, when present, so a fork resumes a driveable
    // control plane and a coherent NIC (see writeSnapshotFile / macRestore).
    const has_ctl = ctx.vs_dev != null and ctx.vsock != null and ctx.agent != null;
    const vs_dev_snap: ?nether.virtio.Device.DeviceState = if (has_ctl) ctx.vs_dev.?.exportState() else null;
    const vsock_snap: ?nether.Vsock.State = if (has_ctl) ctx.vsock.?.exportState() else null;
    const conn_id_snap: i32 = if (has_ctl) ctx.agent.?.conn_id.load(.acquire) else -1;
    const net_dev_snap: ?nether.virtio.Device.DeviceState = if (ctx.net_dev) |nd| nd.exportState() else null;
    // Write while still quiesced (consistent image), then resume.
    const ok = writeSnapshotFile(path, ctx.ram, cpu_snap[0..n], con_snap, blk_snap, uart_snap, gic, ctx.blk_disk, vs_dev_snap, vsock_snap, conn_id_snap, net_dev_snap);
    sn.phase.store(@intFromEnum(hvfb.SnapPhase.resumed), .release);
    std.debug.print("[nether] snapshot {s} to {s} ({d} MiB + state, control-plane={s}, net={s}); guest resumed.\n", .{ if (ok) "written" else "FAILED writing", path, ctx.ram.len / (1024 * 1024), if (has_ctl) "captured" else "absent", if (net_dev_snap != null) "captured" else "absent" });
    return ok;
}

/// `platform.Snapshotter` adapter: cast the opaque ctx back to a SnapCtx and capture.
pub fn snapshotCall(p: *anyopaque, path: [*:0]const u8) bool {
    const ctx: *SnapCtx = @ptrCast(@alignCast(p));
    return captureToFile(ctx, path);
}

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
    const hvf = @import("../hv/hvf.zig");
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
    for (@import("../hv/hvf.zig").SNAPSHOT_SYS_REGS, 0..) |r, i| if (r == 0xc101) break :blk i;
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
    const hvfb = @import("../hv/hvf_backend.zig");
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
    const hvf = @import("../hv/hvf.zig");
    const hvfb = @import("../hv/hvf_backend.zig");
    const sn: *hvfb.SnapCtl = @ptrCast(@alignCast(ctx.snap));
    const n = ctx.num_cpus;

    var t: u32 = 0;
    while (t < 200) : (t += 1) _ = usleep(100_000); // ~20s: let the guest reach the shell

    // --- SAVE-TO-FILE mode: serialize a fork source and keep running. The platform's
    // production path uses the on-demand `__snapshot__` control command (captureToFile)
    // instead of this fixed timer; both share the same capture.
    if (ctx.save) {
        _ = captureToFile(ctx, "nether.snap");
        std.debug.print("[nether] run `nether restore` to fork nether.snap.\n", .{});
        return;
    }

    // --- REWIND mode: capture, let the guest run, then restore in place. -----
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
    const gic = hvfb.gicCaptureAlloc(ctx.allocator); // null on failure -> rewind skips GIC restore (logged)
    defer if (gic) |g| ctx.allocator.free(g);
    if (gic == null) std.debug.print("[nether] snapshot: WARNING GIC capture failed; the rewind will not restore interrupt state\n", .{});
    const con_snap = ctx.con_dev.exportState(); // pointer-free device state
    const blk_snap = ctx.blk_dev.exportState();
    const uart_snap = ctx.uart.exportState();
    const disk_snap = ctx.allocator.alloc(u8, ctx.blk_disk.len) catch return;
    @memcpy(disk_snap, ctx.blk_disk);
    sn.phase.store(@intFromEnum(hvfb.SnapPhase.resumed), .release);
    std.debug.print("\n[nether] SNAPSHOT captured: ram={d}MiB gic={d}B cpus={d}\n", .{ ctx.ram.len / (1024 * 1024), if (gic) |g| g.len else 0, n });

    t = 0;
    while (t < 40) : (t += 1) _ = usleep(100_000); // ~4s: let the guest run and mutate state
    const advanced = countDiff(ctx.ram, ram_snap);

    sn.cpu = cpu_snap; // load the captured contexts for each vCPU to self-restore
    quiesce(sn, ctx.handles, n, @intFromEnum(hvfb.SnapPhase.restoring));
    @memcpy(ctx.ram, ram_snap);
    if (gic) |g| _ = hvfb.gicRestoreState(g);
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
const SNAP_VERSION: u32 = 4; // bumped: header carries a control-plane flag + vsock state
const HDR_SIZE: usize = 128; // header bytes (grew from 64 for the control-plane fields)
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
fn validateHeader(hdr: *const [HDR_SIZE]u8, max_cpus: u32, disk_cap: u64, gic_cap: u64, cpu_sz: u32, dev_sz: u32, uart_sz: u32, vsock_sz: u32) SnapError!void {
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
    // Control-plane section (vsock device + engine state): when present, its engine
    // struct must match this build's layout, same as the cpu/dev/uart fingerprints.
    if (std.mem.readInt(u32, hdr[64..68], .little) == 1 and
        std.mem.readInt(u32, hdr[68..72], .little) != vsock_sz) return error.SnapshotLayoutMismatch;
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
    vs_dev: ?nether.virtio.Device.DeviceState, // vsock transport state (null => no control plane)
    vsock: ?nether.Vsock.State, // vsock engine state
    conn_id: i32, // surviving agent connection id (-1 if none)
    net_dev: ?nether.virtio.Device.DeviceState, // virtio-net transport state (null => no NIC)
) bool {
    // O_NOFOLLOW: when the path comes from __snapshot__ it is jailed (parent resolved),
    // so refuse a pre-existing symlink at the basename that would redirect the write
    // outside the jail. For the demo's plain "nether.snap" this just refuses to clobber
    // a symlink in cwd, which is the safe behavior anyway.
    const fd = hostutil.createTruncNoFollow(path);
    if (fd < 0) return false;
    defer _ = libc.close(fd);

    const ctl = vs_dev != null and vsock != null;
    const net = net_dev != null;
    const dev_sz: usize = @sizeOf(nether.virtio.Device.DeviceState);
    const eng_sz: usize = @sizeOf(nether.Vsock.State);
    const ctl_bytes: usize = (if (ctl) dev_sz + eng_sz else 0) + (if (net) dev_sz else 0);

    // The metadata precedes a page-aligned RAM region (so RAM can be mmap'd COW).
    const meta = HDR_SIZE + cpus.len * @sizeOf(@TypeOf(cpus[0])) + @sizeOf(@TypeOf(con)) +
        @sizeOf(@TypeOf(blk)) + @sizeOf(@TypeOf(uart)) + gic.len + disk.len + ctl_bytes;
    const ram_off = std.mem.alignForward(usize, meta, HOST_PAGE);

    var hdr = [_]u8{0} ** HDR_SIZE;
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
    // Control-plane section: a flag, the engine-state size (layout fingerprint), and
    // the surviving agent conn id. The vsock device-state reuses the dev_sz fingerprint
    // (same virtio.Device.DeviceState type as con/blk).
    std.mem.writeInt(u32, hdr[64..68], if (ctl) @as(u32, 1) else 0, .little);
    std.mem.writeInt(u32, hdr[68..72], @sizeOf(nether.Vsock.State), .little);
    std.mem.writeInt(i32, hdr[72..76], conn_id, .little);
    // virtio-net transport present: a flag; the device-state reuses the dev_sz
    // fingerprint (same virtio.Device.DeviceState type as con/blk/vsock).
    std.mem.writeInt(u32, hdr[76..80], if (net) @as(u32, 1) else 0, .little);
    if (!writeAll(fd, &hdr)) return false;
    for (cpus) |*c| if (!writeAll(fd, std.mem.asBytes(c))) return false;
    if (!writeAll(fd, std.mem.asBytes(&con))) return false;
    if (!writeAll(fd, std.mem.asBytes(&blk))) return false;
    if (!writeAll(fd, std.mem.asBytes(&uart))) return false;
    if (!writeAll(fd, gic)) return false;
    if (!writeAll(fd, disk)) return false;
    if (ctl) {
        if (!writeAll(fd, std.mem.asBytes(&vs_dev.?))) return false;
        if (!writeAll(fd, std.mem.asBytes(&vsock.?))) return false;
    }
    if (net) {
        if (!writeAll(fd, std.mem.asBytes(&net_dev.?))) return false;
    }
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
    handles: [*]u64, // each secondary records its vCPU handle for the control-plane stop
};

fn macRestoreCpu(ctx: *RestoreCtx) void {
    const hvfb = @import("../hv/hvf_backend.zig");
    var vcpu = ctx.vm.createVcpu(ctx.id) catch {
        _ = ctx.ready.fetchAdd(1, .release);
        return;
    };
    defer vcpu.deinit();
    const st: *const hvfb.CpuState = @ptrCast(@alignCast(ctx.state));
    vcpu.restore(st);
    ctx.handles[ctx.id] = vcpu.handle; // for hv_vcpus_exit via the restore Stop
    _ = ctx.ready.fetchAdd(1, .release);
    while (!ctx.go.load(.acquire)) _ = usleep(200);
    _ = vcpu.runSmp(ctx.bus, ctx.power, null, null) catch {};
}

/// The HVF guest stop for the restore path, adapted to `platform.Stop`: request a
/// PSCI poweroff then force the vCPUs out of `hv_vcpu_run` so the run loop returns
/// `.shutdown`. The restore analog of main.zig's HvfStop (kept local to avoid a
/// snapshot->main import cycle). Lives in the macRestore frame; the detached control
/// and watchdog threads hold &it for the forked guest's lifetime.
const RestoreStop = struct {
    power: *nether.Power,
    handles: []const u64,
    num_cpus: u32,
    fn call(p: *anyopaque) void {
        const self: *RestoreStop = @ptrCast(@alignCast(p));
        const hvf = @import("../hv/hvf.zig");
        self.power.request(.shutdown);
        var tries: u32 = 0;
        while (tries < 50) : (tries += 1) {
            _ = hvf.hv_vcpus_exit(self.handles.ptr, self.num_cpus);
            _ = usleep(20_000);
        }
    }
};

/// Validate a snapshot file against THIS build WITHOUT booting it: the header and its
/// struct-layout fingerprints, the section sizes' internal consistency and fit within the
/// file, and the vsock engine state's invariants. Lets the platform vet a pre-baked base
/// (on-disk corruption, a partial write, or version/layout drift after a Nether upgrade)
/// cheaply - no VM, no RAM map. Prints a one-line summary on success; returns an error
/// (with a specific message) on any problem, so the caller exits non-zero. Pure file
/// parsing: it makes no hv_* calls, so it runs without the hypervisor.
pub fn validateSnapshotFile(path: [*:0]const u8) !void {
    const hvfb = @import("../hv/hvf_backend.zig");
    const cpu_sz: u64 = @sizeOf(hvfb.CpuState);
    const dev_sz: u64 = @sizeOf(nether.virtio.Device.DeviceState);
    const uart_sz: u64 = @sizeOf(nether.Pl011.State);
    const eng_sz: u64 = @sizeOf(nether.Vsock.State);

    const fd = libc.open(path, 0, @as(c_int, 0)); // O_RDONLY
    if (fd < 0) {
        std.debug.print("[nether] validate: cannot open {s}\n", .{path});
        return error.OpenFailed;
    }
    defer _ = libc.close(fd);

    var hdr = [_]u8{0} ** HDR_SIZE;
    if (!readExact(fd, &hdr)) {
        std.debug.print("[nether] validate: file too short for a {d}-byte header\n", .{HDR_SIZE});
        return error.BadSnapshot;
    }
    validateHeader(&hdr, hvfb.MAX_SNAP_CPUS, armdev.blk_disk_storage.len, GIC_STATE_MAX, @intCast(cpu_sz), @intCast(dev_sz), @intCast(uart_sz), @intCast(eng_sz)) catch |e| {
        switch (e) {
            error.SnapshotVersionMismatch => std.debug.print("[nether] validate: not format v{d} (baked by a different Nether build); re-bake\n", .{SNAP_VERSION}),
            error.SnapshotLayoutMismatch => std.debug.print("[nether] validate: struct layout differs from this build; re-bake\n", .{}),
            error.BadSnapshot => std.debug.print("[nether] validate: header invalid, corrupt, or truncated\n", .{}),
        }
        return e;
    };

    const num_cpus: u64 = std.mem.readInt(u32, hdr[8..12], .little);
    const ram_size = std.mem.readInt(u64, hdr[24..32], .little);
    const gic_size = std.mem.readInt(u64, hdr[32..40], .little);
    const disk_size = std.mem.readInt(u64, hdr[40..48], .little);
    const ram_off = std.mem.readInt(u64, hdr[48..56], .little);
    const ctl = std.mem.readInt(u32, hdr[64..68], .little) == 1;
    const conn_id = std.mem.readInt(i32, hdr[72..76], .little);
    const net = std.mem.readInt(u32, hdr[76..80], .little) == 1;

    const fsize = libc.lseek(fd, 0, 2); // SEEK_END
    if (fsize < 0) return error.BadSnapshot;
    const file_size: u64 = @intCast(fsize);

    // The metadata sections (header .. just before RAM) must be internally consistent:
    // their sizes sum to `meta`, which writeSnapshotFile page-aligns UP to ram_off. So
    // meta <= ram_off and the gap is less than one page; otherwise the sizes are bogus.
    const ctl_bytes: u64 = if (ctl) dev_sz + eng_sz else 0;
    const net_bytes: u64 = if (net) dev_sz else 0;
    const meta = HDR_SIZE + num_cpus * cpu_sz + 2 * dev_sz + uart_sz + gic_size + disk_size + ctl_bytes + net_bytes;
    if (meta > ram_off or ram_off - meta >= HOST_PAGE) {
        std.debug.print("[nether] validate: section sizes inconsistent with the RAM offset (meta={d}, ram_off={d})\n", .{ meta, ram_off });
        return error.BadSnapshot;
    }
    // And the file must actually hold the RAM region (overflow-safe).
    if (ram_off > file_size or ram_size > file_size - ram_off) {
        std.debug.print("[nether] validate: truncated (RAM region {d}+{d} exceeds file size {d})\n", .{ ram_off, ram_size, file_size });
        return error.BadSnapshot;
    }

    // Validate the vsock engine state in place (the one section with internal invariants;
    // restore gates on these too, so a base failing here would not fork driveably).
    if (ctl) {
        const eng_off: i64 = @intCast(HDR_SIZE + num_cpus * cpu_sz + 2 * dev_sz + uart_sz + gic_size + disk_size + dev_sz);
        _ = libc.lseek(fd, eng_off, 0);
        var st: nether.Vsock.State = undefined;
        if (!readExact(fd, std.mem.asBytes(&st))) return error.BadSnapshot;
        if (!nether.Vsock.validState(&st)) {
            std.debug.print("[nether] validate: vsock engine state corrupt (staging ring out of bounds)\n", .{});
            return error.BadSnapshot;
        }
        if (conn_id >= @as(i32, nether.vsock.MAX_CONNS)) {
            std.debug.print("[nether] validate: saved agent conn id {d} out of range\n", .{conn_id});
            return error.BadSnapshot;
        }
    }

    std.debug.print("[nether] validate: OK - format v{d}, {d} cpus, {d} MiB RAM, gic {d}B, disk {d}B, control-plane={s}, net={s}\n", .{ SNAP_VERSION, num_cpus, ram_size / (1024 * 1024), gic_size, disk_size, if (ctl) "on" else "off", if (net) "on" else "off" });
}

/// Restore a guest from a snapshot file (a cross-process fork): rebuild the VM,
/// map and fill RAM, recreate each vCPU with its captured register context,
/// reinstall the framework GIC state and the virtio device state, and resume.
/// No kernel/DTB load - the snapshot *is* the booted guest.
pub fn macRestore(allocator: std.mem.Allocator, path: [*:0]const u8) !void {
    const hvf = @import("../hv/hvf.zig");
    const hvfb = @import("../hv/hvf_backend.zig");

    const fd = libc.open(path, 0, @as(c_int, 0)); // O_RDONLY
    if (fd < 0) {
        std.debug.print("[nether] restore: cannot open {s}\n", .{path});
        return error.OpenFailed;
    }
    defer _ = libc.close(fd);

    var hdr = [_]u8{0} ** HDR_SIZE;
    if (!readExact(fd, &hdr)) return error.BadSnapshot;
    validateHeader(&hdr, hvfb.MAX_SNAP_CPUS, armdev.blk_disk_storage.len, GIC_STATE_MAX, @sizeOf(hvfb.CpuState), @sizeOf(nether.virtio.Device.DeviceState), @sizeOf(nether.Pl011.State), @sizeOf(nether.Vsock.State)) catch |e| {
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
    const ctl_present = std.mem.readInt(u32, hdr[64..68], .little) == 1;
    const saved_conn_id = std.mem.readInt(i32, hdr[72..76], .little);
    const net_present = std.mem.readInt(u32, hdr[76..80], .little) == 1;

    // The RAM region is mapped copy-on-write by offset (not read), so a file that is
    // too short to contain ram_off + ram_size would not fault here - it would SIGBUS
    // the guest on the first access to the missing tail. Verify the file actually
    // holds the RAM region up front (overflow-safe), then rewind to the metadata.
    const fsize = libc.lseek(fd, 0, 2); // SEEK_END
    _ = libc.lseek(fd, @intCast(HDR_SIZE), 0); // SEEK_SET back to just after the header
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
    // Control-plane state (vsock transport + engine), present iff the base snapshot
    // was taken from a control-mode sandbox. Read right after the disk, matching the
    // write order in writeSnapshotFile.
    var vs_dev_state: nether.virtio.Device.DeviceState = undefined;
    var vsock_state: nether.Vsock.State = undefined;
    if (ctl_present) {
        if (!readExact(fd, std.mem.asBytes(&vs_dev_state))) return error.BadSnapshot;
        if (!readExact(fd, std.mem.asBytes(&vsock_state))) return error.BadSnapshot;
        // Validate the engine ring indices BEFORE importing: a corrupt/bit-flipped base
        // could otherwise drive a host OOB on the staging ring at first drain.
        if (!nether.Vsock.validState(&vsock_state)) {
            std.debug.print("[nether] restore: vsock engine state is corrupt (ring out of bounds); refusing\n", .{});
            return error.BadSnapshot;
        }
        // The surviving agent conn id must index the connection table; reject a bogus
        // one (the relay would @intCast it to u16 and hostSend with it).
        if (saved_conn_id >= @as(i32, nether.vsock.MAX_CONNS)) {
            std.debug.print("[nether] restore: saved agent conn id {d} out of range; refusing\n", .{saved_conn_id});
            return error.BadSnapshot;
        }
    }
    var net_dev_state: nether.virtio.Device.DeviceState = undefined;
    if (net_present) {
        if (!readExact(fd, std.mem.asBytes(&net_dev_state))) return error.BadSnapshot;
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
    var handles: [hvfb.MAX_SNAP_CPUS]u64 = undefined; // vCPU handles for the control-plane stop
    handles[0] = vcpu.handle;
    var ready = std.atomic.Value(u32).init(0);
    var go = std.atomic.Value(bool).init(false);
    var rc: [hvfb.MAX_SNAP_CPUS]RestoreCtx = undefined;
    var s: u32 = 1;
    while (s < num_cpus) : (s += 1) {
        rc[s] = .{ .vm = &vm, .id = s, .bus = &bus, .power = &power, .state = &cpus[s], .ready = &ready, .go = &go, .handles = &handles };
        (std.Thread.spawn(.{}, macRestoreCpu, .{&rc[s]}) catch return).detach();
    }
    while (ready.load(.acquire) < num_cpus - 1) _ = usleep(200); // all redistributors exist (+ handles recorded)

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

    // virtio-blk backing: a persistent host file if the fork's conf sets `disk=` (same as
    // the boot path), else the in-memory disk restored from the snapshot. A file-backed
    // disk persists independently of the snapshot, so the restored disk_size is 0 and the
    // file is the source of truth.
    var blk_path_buf: [1024]u8 = undefined;
    const blk_backing: []u8 = if (conf.confGet("disk", &blk_path_buf)) |_| backing: {
        const mb: usize = @intCast(@max(conf.confGetInt("disk_size_mb", 64), 1));
        break :backing armdev.openDiskFile(@ptrCast(&blk_path_buf), mb * 1024 * 1024) orelse armdev.blk_disk_storage[0..];
    } else armdev.blk_disk_storage[0..];
    var blk = nether.VirtioBlk{ .disk = blk_backing };
    var blk_dev = nether.virtio.Device.init(blk.backend(), gmem);
    var blk_intx = IntxLine{ .intid = armPciIntxIntid(2) };
    blk_dev.intx_ptr = &blk_intx;
    blk_dev.intx_fn = IntxLine.set;
    blk_dev.msi_ptr = &blk_dev;
    blk_dev.msi_fn = armSendMsi;
    blk_dev.importState(&blk_state);
    try pci_host.addFunction(blk_dev.function(2, 0));

    // Function 0:3.0 - virtio-vsock, recreated only when the base snapshot carried the
    // control plane. The engine is heap-allocated (large connection state); importState
    // restores its connection table + listen registry + staging ring, so the agent's
    // pre-fork connection resumes mid-stream (the load-bearing "survive, not reconnect"
    // decision). Callbacks are re-wired to THIS process's handlers.
    var vs_engine: ?*nether.Vsock = null;
    defer if (vs_engine) |v| allocator.destroy(v);
    var vsdev: nether.VsockDev = undefined;
    var vs_dev: nether.virtio.Device = undefined;
    var vs_intx: IntxLine = undefined;
    if (ctl_present) {
        const vs = try allocator.create(nether.Vsock);
        vs.* = .{ .guest_cid = 3 };
        vs.importState(&vsock_state); // restore the connection table, listens, staging ring
        vs_engine = vs;
        vsdev = .{ .engine = vs };
        vs_dev = nether.virtio.Device.init(vsdev.backend(), gmem);
        vs_intx = .{ .intid = armPciIntxIntid(3) };
        vs_dev.intx_ptr = &vs_intx;
        vs_dev.intx_fn = IntxLine.set;
        vs_dev.msi_ptr = &vs_dev;
        vs_dev.msi_fn = armSendMsi;
        vs_dev.importState(&vs_dev_state); // restore the virtqueue transport state
        try pci_host.addFunction(vs_dev.function(3, 0));
        vsdev.attach(&vs_dev);
    }

    // Function 0:4.0 - virtio-net, recreated when the base ran with net=1. Only the
    // device (virtqueue) transport is restored so the guest's NIC driver resumes; the
    // slirp NAT engine starts FRESH (it holds host sockets a fork can't inherit, so the
    // guest re-establishes its TCP flows). Firewall/rate come from the fork's nether.conf.
    var net_be: nether.VirtioNet = undefined;
    var net_dev: nether.virtio.Device = undefined;
    var net_intx: IntxLine = undefined;
    var slirp_stack: nether.Slirp = undefined;
    if (net_present) {
        net_be = .{};
        net_dev = nether.virtio.Device.init(net_be.backend(), gmem);
        net_intx = .{ .intid = armPciIntxIntid(4) };
        net_dev.intx_ptr = &net_intx;
        net_dev.intx_fn = IntxLine.set;
        net_dev.msi_ptr = &net_dev;
        net_dev.msi_fn = armSendMsi;
        net_dev.importState(&net_dev_state); // restore the virtqueue transport state
        try pci_host.addFunction(net_dev.function(4, 0));
        net_be.attach(&net_dev);
        slirp_stack = .{};
        armdev.applyNetFirewall(&slirp_stack); // per-fork egress firewall from nether.conf
        slirp_stack.out_fn = armdev.slirpToNet;
        slirp_stack.out_ctx = &net_be;
        net_be.on_tx = armdev.netToSlirp;
        net_be.on_tx_ctx = &slirp_stack;
        if (std.Thread.spawn(.{}, armdev.slirpPollLoop, .{&slirp_stack})) |t| t.detach() else |_| {}
    }

    var dev_buf: [4]*nether.virtio.Device = undefined;
    var ndev: usize = 0;
    dev_buf[ndev] = &con_dev;
    ndev += 1;
    dev_buf[ndev] = &blk_dev;
    ndev += 1;
    if (ctl_present) {
        dev_buf[ndev] = &vs_dev;
        ndev += 1;
    }
    if (net_present) {
        dev_buf[ndev] = &net_dev;
        ndev += 1;
    }
    var bar_win = PciBarWindow{ .devs = dev_buf[0..ndev] };
    try bus.addMmio(bar_win.device());
    try bus.addMmio(pci_host.mmioDevice());

    const saved_termios = armEnableRawMode();
    defer if (saved_termios) |t| armRestoreTermios(t);
    if (std.Thread.spawn(.{}, armStdinPump, .{&uart})) |t| t.detach() else |_| {}

    std.debug.print("[nether] RESTORED from {s}: {d} cpus, {d} MiB RAM, gic {d}B, control-plane={s}, net={s}. Resuming the forked guest.\n", .{ path, num_cpus, ram_size / (1024 * 1024), gic_size, if (ctl_present) "on" else "off", if (net_present) "on (slirp engine fresh)" else "off" });

    // Narrowed NOTE: a base snapshot taken from a NON-control sandbox carries no vsock/
    // agent state, so this fork is console + virtio-blk only even if the operator set a
    // control_socket. Say so (rather than leave the missing socket a silent mystery);
    // re-snapshot from a control-mode sandbox for a driveable fork.
    if (!ctl_present) {
        var sock_buf: [256]u8 = undefined;
        if (conf.confGet("control_socket", &sock_buf) != null or conf.modeOn("control", "nether-control")) {
            std.debug.print("[nether] restore: NOTE this snapshot has no control plane (base was a non-control sandbox); " ++
                "the forked guest is console + virtio-blk only - no control socket. Re-snapshot from a " ++
                "control-mode sandbox for a driveable fork.\n", .{});
        }
    }

    // Control plane: rebuild the observe/meter/run core FRESH (each fork is a new
    // billable session), re-wire the vsock engine to this process's agent handler,
    // open the control socket, and arm the govern watchdogs - so a forked sandbox is
    // driveable over the control protocol exactly like a fresh boot. The agent's
    // surviving connection id comes across from the snapshot, so a command round-trips
    // immediately with no reconnect.
    var core = control.Core{};
    var render: nether.Render = undefined;
    var ctl_ctx: control.ControlCtx = undefined;
    var hvf_stop = RestoreStop{ .power = &power, .handles = handles[0..num_cpus], .num_cpus = num_cpus };
    var watchdogs: platform.Watchdogs = undefined;
    if (ctl_present) {
        core.init(ram_size / (1024 * 1024), num_cpus, @intCast(conf.confGetInt("max_output_bytes", control.DEFAULT_MAX_OUTPUT_BYTES)));
        core.x402 = conf.confBool("x402"); // settlement mode (from the fork's nether.conf; default off)
        core.journal.emit(.life, "restored from snapshot fork");

        // Render pillar: tee agent output into a VT screen for __screen__.
        const rows: u16 = @intCast(std.math.clamp(conf.confGetInt("screen_rows", 24), 1, 200));
        const cols: u16 = @intCast(std.math.clamp(conf.confGetInt("screen_cols", 80), 1, 400));
        render = try nether.Render.init(allocator, rows, cols);
        core.agent.render = &render;

        // Re-wire the engine callbacks to this process and resume the agent connection.
        const vs = vs_engine.?;
        vs.on_event = control.agentEvent;
        vs.on_event_ctx = &core.agent;
        _ = vsdev.hostListen(5000); // idempotent (restored listen set already has it); enables future reconnects
        core.agent.conn_id.store(saved_conn_id, .release); // the surviving connection drives immediately

        // Wire the (fresh) NAT engine into the meter + journal so __stats__ reports
        // egress bytes and __netlog__ records flows for this fork session.
        if (net_present) {
            core.meter.net = &slirp_stack;
            slirp_stack.journal = &core.journal;
        }

        var sock_path_buf: [256]u8 = undefined;
        const have_sock_conf = conf.confGet("control_socket", &sock_path_buf) != null;
        const ctl_path: [*:0]const u8 = if (have_sock_conf) @ptrCast(&sock_path_buf) else "/tmp/nether.sock";
        const net_on = net_present; // the device's presence, not the fork conf (the guest NIC is bound)
        control.startControl(&ctl_ctx, .{
            .vsdev = &vsdev,
            .agent = &core.agent,
            .meter = &core.meter,
            .journal = &core.journal,
            .gpu = null, // gpu state is not part of the snapshot
            .stop = .{ .ctx = &hvf_stop, .func = RestoreStop.call },
            .path = ctl_path,
            .allocator = allocator,
            .info = .{
                .cpus = num_cpus,
                .ram_mb = ram_size / (1024 * 1024),
                .net = net_on,
                .firewall = net_on and !conf.confBool("net_open"),
                .gpu = false,
                .max_runtime_s = conf.confGetInt("max_runtime_s", 0),
                .max_cpu_s = conf.confGetInt("max_cpu_s", 0),
                .idle_timeout_s = conf.confGetInt("idle_timeout_s", 0),
                .rate_kbps = conf.confGetInt("net_rate_kbps", 0),
                .max_output_bytes = conf.confGetInt("max_output_bytes", control.DEFAULT_MAX_OUTPUT_BYTES),
                .x402 = core.x402,
            },
        });

        watchdogs = .{
            .stop = .{ .ctx = &hvf_stop, .func = RestoreStop.call },
            .activity = &core.meter.last_activity_ms,
            .runtime_ms = @intCast(conf.confGetInt("max_runtime_s", 0) * 1000),
            .idle_ms = @intCast(conf.confGetInt("idle_timeout_s", 0) * 1000),
            .cpu_ms = @intCast(conf.confGetInt("max_cpu_s", 0) * 1000),
        };
        watchdogs.arm();
    }
    defer if (ctl_present) render.deinit();

    go.store(true, .release); // release secondaries; run cpu0
    const reason = vcpu.runSmp(&bus, &power, null, null) catch |err| {
        std.debug.print("\n[nether] forked guest stopped: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("\n[nether] forked guest {s}.\n", .{@tagName(reason)});
    if (ctl_present) core.finalUsage(@tagName(reason)); // the teardown bill for the fork session
}

// --- tests -----------------------------------------------------------------
const testing = std.testing;

test "snapshot header validation gates version, layout, and oversized sizes" {
    const CPU: u32 = 100;
    const DEV: u32 = 200;
    const UART: u32 = 50;
    const VSOCK: u32 = 300;
    const DISK_CAP: u64 = 1024 * 1024;
    const GIC_CAP: u64 = GIC_STATE_MAX;

    // A well-formed header for this "build".
    var hdr = [_]u8{0} ** HDR_SIZE;
    std.mem.writeInt(u32, hdr[0..4], SNAP_MAGIC, .little);
    std.mem.writeInt(u32, hdr[4..8], SNAP_VERSION, .little);
    std.mem.writeInt(u32, hdr[8..12], 4, .little); // num_cpus
    std.mem.writeInt(u32, hdr[12..16], CPU, .little);
    std.mem.writeInt(u64, hdr[24..32], 512 * 1024 * 1024, .little); // ram_size
    std.mem.writeInt(u64, hdr[32..40], 126405, .little); // gic_size
    std.mem.writeInt(u64, hdr[40..48], DISK_CAP, .little); // disk_size == cap (ok)
    std.mem.writeInt(u32, hdr[56..60], DEV, .little);
    std.mem.writeInt(u32, hdr[60..64], UART, .little);
    std.mem.writeInt(u32, hdr[64..68], 1, .little); // control-plane present
    std.mem.writeInt(u32, hdr[68..72], VSOCK, .little); // vsock engine-state fingerprint
    try validateHeader(&hdr, 8, DISK_CAP, GIC_CAP, CPU, DEV, UART, VSOCK); // accepts a good header

    var bad = hdr;
    std.mem.writeInt(u32, bad[0..4], 0xdead_beef, .little); // wrong magic
    try testing.expectError(error.BadSnapshot, validateHeader(&bad, 8, DISK_CAP, GIC_CAP, CPU, DEV, UART, VSOCK));

    bad = hdr;
    std.mem.writeInt(u32, bad[4..8], SNAP_VERSION + 1, .little); // version mismatch
    try testing.expectError(error.SnapshotVersionMismatch, validateHeader(&bad, 8, DISK_CAP, GIC_CAP, CPU, DEV, UART, VSOCK));

    // Layout drift: this build's cpu struct size differs from the file's fingerprint.
    try testing.expectError(error.SnapshotLayoutMismatch, validateHeader(&hdr, 8, DISK_CAP, GIC_CAP, CPU + 1, DEV, UART, VSOCK));

    // Layout drift in the control-plane section: the vsock engine struct size differs.
    try testing.expectError(error.SnapshotLayoutMismatch, validateHeader(&hdr, 8, DISK_CAP, GIC_CAP, CPU, DEV, UART, VSOCK + 1));

    // A non-control snapshot (flag 0) ignores the vsock fingerprint entirely.
    bad = hdr;
    std.mem.writeInt(u32, bad[64..68], 0, .little); // control-plane absent
    try validateHeader(&bad, 8, DISK_CAP, GIC_CAP, CPU, DEV, UART, VSOCK + 1);

    bad = hdr;
    std.mem.writeInt(u64, bad[40..48], DISK_CAP + 1, .little); // disk would overrun the buffer
    try testing.expectError(error.BadSnapshot, validateHeader(&bad, 8, DISK_CAP, GIC_CAP, CPU, DEV, UART, VSOCK));

    bad = hdr;
    std.mem.writeInt(u64, bad[32..40], GIC_CAP + 1, .little); // absurd gic size
    try testing.expectError(error.BadSnapshot, validateHeader(&bad, 8, DISK_CAP, GIC_CAP, CPU, DEV, UART, VSOCK));

    bad = hdr;
    std.mem.writeInt(u32, bad[8..12], 9, .little); // too many cpus
    try testing.expectError(error.BadSnapshot, validateHeader(&bad, 8, DISK_CAP, GIC_CAP, CPU, DEV, UART, VSOCK));

    bad = hdr;
    std.mem.writeInt(u64, bad[24..32], 0, .little); // zero ram
    try testing.expectError(error.BadSnapshot, validateHeader(&bad, 8, DISK_CAP, GIC_CAP, CPU, DEV, UART, VSOCK));
}
