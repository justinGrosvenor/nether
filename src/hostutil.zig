//! Host-OS primitives shared by the macOS/HVF runner and its control/snapshot
//! plumbing: the libc bindings the VMM uses directly (file + Unix-socket calls),
//! a millisecond clock, and small file helpers. Kept apart from main.zig so the
//! control and snapshot modules can depend on these without depending on the boot
//! orchestration.

const std = @import("std");

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
    pub extern "c" fn getpeereid(fd: c_int, euid: *u32, egid: *u32) c_int;
    pub extern "c" fn getuid() u32;
};
pub extern "c" fn usleep(usec: c_uint) c_int;

pub const AF_UNIX: c_int = 1;
pub const SOCK_STREAM: c_int = 1;
pub const SockaddrUn = extern struct {
    len: u8 = 0,
    family: u8 = AF_UNIX,
    path: [104]u8 = [_]u8{0} ** 104,
};

// macOS timeval: tv_sec is time_t (i64), tv_usec is suseconds_t (i32).
const timeval = extern struct { sec: i64, usec: i32 };
extern "c" fn gettimeofday(tv: *timeval, tz: ?*anyopaque) c_int;

pub fn nowMs() i64 {
    var tv: timeval = .{ .sec = 0, .usec = 0 };
    _ = gettimeofday(&tv, null);
    return tv.sec * 1000 + @divTrunc(tv.usec, 1000);
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
    return buf;
}

/// Copy a path slice into `buf` as a NUL-terminated C string for libc calls.
pub fn cpath(buf: []u8, p: []const u8) ?[*:0]const u8 {
    if (p.len + 1 > buf.len) return null;
    @memcpy(buf[0..p.len], p);
    buf[p.len] = 0;
    return @ptrCast(buf.ptr);
}
