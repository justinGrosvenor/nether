//! KVM/x86 cross-process fork: serialize a running guest to an image file and
//! re-create it in a fresh process. The HVF backend's snapshot machinery is
//! aarch64-specific (CpuState, GIC, PL011, the virtual counter), so this is the
//! x86 peer built on kvm_backend's saveState/restoreState + the KVM clock.
//!
//! Image layout (native-endian, same-host/same-build):
//!   [0..128)     header (magic, version, num_cpus, cpu_sz, ram_size, ram_off)
//!   [128..R)     metadata: num_cpus * CpuState, then ClockData, then IOAPIC redir
//!   [R..end)     guest RAM, page-aligned, sparse-written (zero pages are holes)
//!
//! RAM is written sparse (holes read back as zero) and, on restore, read straight
//! into the fresh guest's anonymous RAM - so a hole costs nothing and restores as
//! the guest's original zero page. (COW-mmap sharing of a common base is the next
//! optimization; correctness first.)

const std = @import("std");
const kvm = @import("kvm.zig");
const kb = @import("kvm_backend.zig");
const ioapic = @import("ioapic.zig");

// libc file I/O (Linux-only module; the KVM path always links libc). Flags are the
// Linux x86_64 values.
const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0o100;
const O_TRUNC: c_int = 0o1000;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn pwrite(fd: c_int, buf: [*]const u8, n: usize, off: i64) isize;
extern "c" fn pread(fd: c_int, buf: [*]u8, n: usize, off: i64) isize;
extern "c" fn ftruncate(fd: c_int, len: i64) c_int;

pub const MAGIC: u32 = 0x564b_534e; // 'NSKV' little-endian
pub const VERSION: u32 = 1;
const HDR: usize = 128;
const PAGE: usize = 4096; // x86 host page (mmap/offset alignment)
const NUM_GSI = 24; // IOAPIC redirection entries (ioapic.zig)

const CpuState = kb.Vcpu.CpuState;

pub const MAX_SNAP_CPUS = 8;

extern "c" fn usleep(usec: c_uint) c_int;

pub const Error = error{ WriteFailed, BadImage, VersionMismatch, LayoutMismatch, TooManyCpus };

/// Quiesce every vCPU out of KVM_RUN, capture full state + RAM to `path`, then let
/// the guest resume. Runs on a thread OTHER than the vCPU threads (it signals them
/// and reads their fds while parked). For cross-process fork the caller exits the
/// process after this returns; resume-then-exit is harmless.
pub fn capture(
    vm: *kb.Vm,
    vcpus: []kb.Vcpu,
    ram: []const u8,
    apic: *const ioapic.IoApic,
    pause: *kb.Pause,
    path: [*:0]const u8,
) Error!void {
    if (vcpus.len > MAX_SNAP_CPUS) return error.TooManyCpus;
    // Quiesce: ask every vCPU to leave KVM_RUN, kick each with the force-exit
    // signal, and wait until all have parked in Pause.wait (out of KVM_RUN).
    pause.request.store(true, .release);
    for (vcpus) |*v| v.requestExit();
    var spins: u32 = 0;
    while (pause.parked.load(.acquire) < vcpus.len) {
        _ = usleep(100);
        spins += 1;
        if (spins > 100_000) break; // ~10s safety valve
        for (vcpus) |*v| v.requestExit(); // re-kick a vCPU that re-entered before parking
    }

    // Every vCPU is parked; its fd is safe to GET from this thread.
    var states: [MAX_SNAP_CPUS]CpuState = undefined;
    for (vcpus, 0..) |*v, i| states[i] = v.saveState() catch return error.WriteFailed;
    const clk = vm.getClock() catch kvm.ClockData{ .clock = 0, .flags = 0 };

    const err = writeImage(path, ram, states[0..vcpus.len], clk, apic.redir);

    // Resume the guest (a no-op for the guest if the caller now exits).
    pause.request.store(false, .release);
    return err;
}

/// The fixed metadata following the header: per-vCPU state, the paravirt clock,
/// and the userspace IOAPIC's redirection table. Size is num_cpus-dependent, so
/// callers compute ram_off = align(HDR + metaLen(num_cpus), PAGE).
fn metaLen(num_cpus: u32) usize {
    return @as(usize, num_cpus) * @sizeOf(CpuState) + @sizeOf(kvm.ClockData) + NUM_GSI * 8;
}

fn alignUp(n: usize, a: usize) usize {
    return (n + a - 1) & ~(a - 1);
}

fn writeAt(fd: c_int, buf: []const u8, off: usize) Error!void {
    if (pwrite(fd, buf.ptr, buf.len, @intCast(off)) != @as(isize, @intCast(buf.len))) return error.WriteFailed;
}
fn readAt(fd: c_int, buf: []u8, off: usize) Error!usize {
    const n = pread(fd, buf.ptr, buf.len, @intCast(off));
    if (n < 0) return error.BadImage;
    return @intCast(n);
}
fn wr32(fd: c_int, off: usize, v: u32) Error!void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try writeAt(fd, &b, off);
}
fn wr64(fd: c_int, off: usize, v: u64) Error!void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    try writeAt(fd, &b, off);
}

/// Serialize a quiesced guest to `path`. `ram` is the whole guest RAM slice,
/// `cpus` the captured per-vCPU state, `clock` the kvmclock, `redir` the IOAPIC
/// table. Caller must have every vCPU parked (out of KVM_RUN) before calling.
pub fn writeImage(
    path: [*:0]const u8,
    ram: []const u8,
    cpus: []const CpuState,
    clock: kvm.ClockData,
    redir: [NUM_GSI]u64,
) Error!void {
    const ram_off = alignUp(HDR + metaLen(@intCast(cpus.len)), PAGE);
    const fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600);
    if (fd < 0) return error.WriteFailed;
    defer _ = close(fd);

    // Header.
    try wr32(fd, 0, MAGIC);
    try wr32(fd, 4, VERSION);
    try wr32(fd, 8, @intCast(cpus.len));
    try wr32(fd, 12, @sizeOf(CpuState));
    try wr64(fd, 16, ram.len);
    try wr64(fd, 24, ram_off);

    // Metadata region.
    var off: usize = HDR;
    for (cpus) |*c| {
        try writeAt(fd, std.mem.asBytes(c), off);
        off += @sizeOf(CpuState);
    }
    try writeAt(fd, std.mem.asBytes(&clock), off);
    off += @sizeOf(kvm.ClockData);
    for (redir) |r| {
        try wr64(fd, off, r);
        off += 8;
    }

    // Sparse RAM: skip page-aligned all-zero runs (leaving file holes) so an image
    // is roughly the guest's touched footprint, not its full size.
    if (ftruncate(fd, @intCast(ram_off + ram.len)) != 0) return error.WriteFailed;
    var i: usize = 0;
    while (i < ram.len) : (i += PAGE) {
        const end = @min(i + PAGE, ram.len);
        const page = ram[i..end];
        if (isZero(page)) continue;
        try writeAt(fd, page, ram_off + i);
    }
}

fn isZero(b: []const u8) bool {
    for (b) |x| if (x != 0) return false;
    return true;
}

/// Parsed header + open fd of a restore image. The caller reads metadata and RAM
/// with the accessors, then closes via `deinit`.
pub const Image = struct {
    fd: c_int,
    num_cpus: u32,
    ram_size: u64,
    ram_off: u64,

    pub fn load(path: [*:0]const u8) Error!Image {
        const fd = open(path, O_RDONLY, 0);
        if (fd < 0) return error.BadImage;
        errdefer _ = close(fd);
        var hdr: [HDR]u8 = undefined;
        if (try readAt(fd, &hdr, 0) < HDR) return error.BadImage;
        if (std.mem.readInt(u32, hdr[0..4], .little) != MAGIC) return error.BadImage;
        if (std.mem.readInt(u32, hdr[4..8], .little) != VERSION) return error.VersionMismatch;
        if (std.mem.readInt(u32, hdr[12..16], .little) != @sizeOf(CpuState)) return error.LayoutMismatch;
        return .{
            .fd = fd,
            .num_cpus = std.mem.readInt(u32, hdr[8..12], .little),
            .ram_size = std.mem.readInt(u64, hdr[16..24], .little),
            .ram_off = std.mem.readInt(u64, hdr[24..32], .little),
        };
    }

    pub fn deinit(self: *Image) void {
        _ = close(self.fd);
    }

    /// Read vCPU `i`'s captured state.
    pub fn cpu(self: *Image, i: u32) Error!CpuState {
        var c: CpuState = undefined;
        const off = HDR + @as(usize, i) * @sizeOf(CpuState);
        if (try readAt(self.fd, std.mem.asBytes(&c), off) < @sizeOf(CpuState)) return error.BadImage;
        return c;
    }

    pub fn clock(self: *Image) Error!kvm.ClockData {
        var c: kvm.ClockData = undefined;
        _ = try readAt(self.fd, std.mem.asBytes(&c), HDR + @as(usize, self.num_cpus) * @sizeOf(CpuState));
        return c;
    }

    pub fn redir(self: *Image) Error![NUM_GSI]u64 {
        var r: [NUM_GSI]u64 = undefined;
        const base = HDR + @as(usize, self.num_cpus) * @sizeOf(CpuState) + @sizeOf(kvm.ClockData);
        var buf: [NUM_GSI * 8]u8 = undefined;
        _ = try readAt(self.fd, &buf, base);
        for (&r, 0..) |*e, i| e.* = std.mem.readInt(u64, buf[i * 8 ..][0..8], .little);
        return r;
    }

    /// Fill `ram` (the fresh guest's zero-filled anon RAM slice) from the image.
    /// Sparse holes read back as zero - exactly the guest's original zero pages -
    /// and any tail past the last written page stays zero.
    pub fn readRam(self: *Image, ram: []u8) Error!void {
        var got: usize = 0;
        while (got < ram.len) {
            const n = try readAt(self.fd, ram[got..], @intCast(self.ram_off + got));
            if (n == 0) break; // EOF: the rest is holes
            got += n;
        }
    }
};
