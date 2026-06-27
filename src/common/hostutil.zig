//! Host-OS primitives shared by the macOS/HVF runner and its control/snapshot
//! plumbing: the libc bindings the VMM uses directly (file + Unix-socket calls),
//! a millisecond clock, and small file helpers. Kept apart from main.zig so the
//! control and snapshot modules can depend on these without depending on the boot
//! orchestration.

const std = @import("std");
const builtin = @import("builtin");

pub const libc = struct {
    pub extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;
    pub extern "c" fn close(fd: c_int) c_int;
    pub extern "c" fn read(fd: c_int, buf: [*]u8, nbyte: usize) isize;
    pub extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
    pub extern "c" fn write(fd: c_int, buf: [*]const u8, nbyte: usize) isize;
    // Unix-domain control socket + a pipe to relay the guest agent's replies.
    pub extern "c" fn socket(domain: c_int, ty: c_int, proto: c_int) c_int;
    pub extern "c" fn bind(fd: c_int, addr: *const SockaddrUn, len: u32) c_int;
    pub extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
    pub extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
    pub extern "c" fn unlink(path: [*:0]const u8) c_int;
    pub extern "c" fn pipe(fds: *[2]c_int) c_int;
    // Control-socket access control: tighten the bound socket to owner-only and
    // verify the connecting peer's uid (the socket grants full control of the VM).
    pub extern "c" fn fchmod(fd: c_int, mode: c_uint) c_int;
    pub extern "c" fn getuid() u32;
    // Peer-credential check: getpeereid on macOS/BSD, SO_PEERCRED via getsockopt on
    // Linux. Both are declared; only the host's path is reachable (comptime branch),
    // so the other never links. See peerUid below.
    pub extern "c" fn getpeereid(fd: c_int, euid: *u32, egid: *u32) c_int;
    pub extern "c" fn getsockopt(fd: c_int, level: c_int, optname: c_int, optval: *anyopaque, optlen: *u32) c_int;
    pub extern "c" fn socketpair(domain: c_int, ty: c_int, proto: c_int, fds: *[2]c_int) c_int;
    // Canonicalize a path (resolving symlinks/.. ) so file transfers can be confined
    // to a jail directory. `resolved` must hold at least PATH_MAX (1024) bytes.
    pub extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;
};
pub extern "c" fn usleep(usec: c_uint) c_int;

pub const AF_UNIX: c_int = 1; // same on macOS and Linux
pub const SOCK_STREAM: c_int = 1; // same on macOS and Linux

// sockaddr_un differs by OS: BSD/macOS leads with a 1-byte sun_len then a u8 family;
// Linux has a u16 sun_family and no length byte (and a 108-byte path). Selected at
// comptime so the control socket binds correctly on both. `path` sits at the same
// offset (2) on both, so callers compute the address length via @offsetOf.
pub const SockaddrUn = if (builtin.os.tag == .macos)
    extern struct { len: u8 = 0, family: u8 = AF_UNIX, path: [104]u8 = [_]u8{0} ** 104 }
else
    extern struct { family: u16 = AF_UNIX, path: [108]u8 = [_]u8{0} ** 108 };

/// The connecting peer's effective uid on a Unix-domain socket, or null on error.
/// getpeereid on macOS/BSD; SO_PEERCRED (struct ucred) on Linux. Used to gate the
/// control socket to its owner regardless of host.
pub fn peerUid(fd: c_int) ?u32 {
    if (builtin.os.tag == .macos) {
        var euid: u32 = 0;
        var egid: u32 = 0;
        if (libc.getpeereid(fd, &euid, &egid) != 0) return null;
        return euid;
    } else {
        const Ucred = extern struct { pid: i32 = 0, uid: u32 = 0, gid: u32 = 0 };
        const SOL_SOCKET: c_int = 1; // Linux
        const SO_PEERCRED: c_int = 17; // Linux
        var cred = Ucred{};
        var len: u32 = @sizeOf(Ucred);
        if (libc.getsockopt(fd, SOL_SOCKET, SO_PEERCRED, @ptrCast(&cred), &len) != 0) return null;
        return cred.uid;
    }
}

// macOS timeval: tv_sec is time_t (i64), tv_usec is suseconds_t (i32).
const timeval = extern struct { sec: i64, usec: i32 };
extern "c" fn gettimeofday(tv: *timeval, tz: ?*anyopaque) c_int;

pub fn nowMs() i64 {
    var tv: timeval = .{ .sec = 0, .usec = 0 };
    _ = gettimeofday(&tv, null);
    return tv.sec * 1000 + @divTrunc(tv.usec, 1000);
}

// struct rusage begins with two timevals (ru_utime, ru_stime); the many `long`
// fields after them we don't read. The timeval's usec is i32 on macOS (suseconds_t)
// and i64 on Linux, but both pad to 16 bytes, so ru_stime lands at offset 16 on both
// - the layout matches each ABI. `tail` absorbs the remainder of the kernel's write
// (struct rusage is ~144 bytes; getrusage fills it whole) so we never overflow.
const RuTimeval = if (builtin.os.tag == .macos)
    extern struct { sec: i64 = 0, usec: i32 = 0 }
else
    extern struct { sec: i64 = 0, usec: i64 = 0 };
const Rusage = extern struct {
    utime: RuTimeval = .{},
    stime: RuTimeval = .{},
    tail: [256]u8 = [_]u8{0} ** 256,
};
extern "c" fn getrusage(who: c_int, usage: *Rusage) c_int;

/// Total CPU time (user + system) the whole nether process has used, in ms. One
/// nether process is one sandbox, so this is the sandbox's compute cost - a reliable,
/// kernel-accounted signal that advances for native compute-bound guests (unlike the
/// per-vCPU exec-time API, which under-counts). POSIX, so it works on both backends.
pub fn processCpuMs() u64 {
    var ru: Rusage = .{};
    if (getrusage(0, &ru) != 0) return 0; // RUSAGE_SELF = 0
    const u = ru.utime.sec * 1000 + @divTrunc(@as(i64, ru.utime.usec), 1000);
    const s = ru.stime.sec * 1000 + @divTrunc(@as(i64, ru.stime.usec), 1000);
    const total = u + s;
    return if (total < 0) 0 else @intCast(total);
}

/// Write all of `buf` to `fd` (returns false on a short/failed write).
pub fn writeAll(fd: c_int, buf: []const u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const w = libc.write(fd, buf.ptr + off, buf.len - off);
        if (w <= 0) return false;
        off += @intCast(w);
    }
    return true;
}

/// Read exactly `buf.len` bytes from `fd` (returns false on EOF/error first).
pub fn readExact(fd: c_int, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const r = libc.read(fd, buf.ptr + off, buf.len - off);
        if (r <= 0) return false;
        off += @intCast(r);
    }
    return true;
}

/// Read a whole file into a freshly allocated buffer (caller frees).
pub fn readFileMac(allocator: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
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
    // A short read (error or EOF mid-file) must not silently yield a partial file:
    // callers (e.g. __put__) would transfer truncated data as if complete.
    if (off != size) return error.ShortRead;
    return buf;
}

/// Copy a path slice into `buf` as a NUL-terminated C string for libc calls.
pub fn cpath(buf: []u8, p: []const u8) ?[*:0]const u8 {
    if (p.len + 1 > buf.len) return null;
    @memcpy(buf[0..p.len], p);
    buf[p.len] = 0;
    return @ptrCast(buf.ptr);
}

test "processCpuMs is monotonic and advances under load" {
    const before = processCpuMs();
    // Burn measurable CPU in-thread; doNotOptimizeAway keeps the loop from folding.
    var acc: u64 = 0;
    var i: u64 = 0;
    while (i < 80_000_000) : (i += 1) acc +%= i *% 2654435761;
    std.mem.doNotOptimizeAway(acc);
    const after = processCpuMs();
    try std.testing.expect(after >= before); // never goes backward
    try std.testing.expect(after > 0); // the burn registered some CPU time
}
