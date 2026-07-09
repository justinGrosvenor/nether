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
    pub extern "c" fn ftruncate(fd: c_int, length: i64) c_int; // size a backing file (persistent disk)
    pub extern "c" fn msync(addr: *anyopaque, len: usize, flags: c_int) c_int; // flush a MAP_SHARED mapping to its file
    pub extern "c" fn write(fd: c_int, buf: [*]const u8, nbyte: usize) isize;
    pub extern "c" fn isatty(fd: c_int) c_int; // 1 for a terminal, 0 otherwise (no errno noise on a non-tty)
    // Unix-domain control socket + a pipe to relay the guest agent's replies.
    pub extern "c" fn socket(domain: c_int, ty: c_int, proto: c_int) c_int;
    pub extern "c" fn bind(fd: c_int, addr: *const SockaddrUn, len: u32) c_int;
    pub extern "c" fn connect(fd: c_int, addr: *const SockaddrUn, len: u32) c_int;
    pub extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
    pub extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
    pub extern "c" fn unlink(path: [*:0]const u8) c_int;
    // Jail-relative file access (openJailedAt): open/unlink RELATIVE to a pinned
    // directory fd, so a transfer path cannot be re-pointed between its containment
    // check and its open (the realpath-then-open TOCTOU; see control.zig jailedPath).
    pub extern "c" fn openat(dirfd: c_int, path: [*:0]const u8, oflag: c_int, ...) c_int;
    pub extern "c" fn unlinkat(dirfd: c_int, path: [*:0]const u8, flag: c_int) c_int;
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
    pub extern "c" fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: u32) c_int;
    pub extern "c" fn send(fd: c_int, buf: [*]const u8, len: usize, flags: c_int) isize;
    pub extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int; // variadic: arm64 macOS ABI differs from a fixed decl
    pub extern "c" fn poll(fds: *Pollfd, nfds: c_uint, timeout: c_int) c_int;
    pub extern "c" fn shutdown(fd: c_int, how: c_int) c_int;
    pub extern "c" fn socketpair(domain: c_int, ty: c_int, proto: c_int, fds: *[2]c_int) c_int;
    // Canonicalize a path (resolving symlinks/.. ) so file transfers can be confined
    // to a jail directory. `resolved` must hold at least PATH_MAX bytes - 1024 on macOS but
    // 4096 on Linux (realpath writes the full canonical path); callers size buffers for 4096.
    pub extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;
    // Signal disposition: handler passed as an integer (SIG_IGN) or a function address
    // (@intFromPtr of a C-callconv handler). Return is the previous handler, ignored.
    pub extern "c" fn signal(sig: c_int, handler: usize) usize;
    pub extern "c" fn raise(sig: c_int) c_int; // deliver a signal to this process (for tests)
};

/// Bound how long a `write` to `fd` blocks when the peer's receive buffer is full
/// (SO_SNDTIMEO). Used on control-client sockets so a wedged consumer that stops reading
/// cannot make the relay's write block forever - and thereby stall the pipe -> agent ->
/// vCPU chain that would freeze the guest. A timed-out write returns short/EAGAIN, which
/// the relay treats as "drop this client". BSD/macOS socket-option values; on Linux this
/// is a graceful no-op (wrong constants -> setsockopt errors, ignored) until the port.
pub fn setSendTimeout(fd: c_int, ms: u32) void {
    const SOL_SOCKET: c_int = if (builtin.os.tag == .macos) 0xffff else 1;
    const SO_SNDTIMEO: c_int = if (builtin.os.tag == .macos) 0x1005 else 21;
    const tv = timeval{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * 1000) };
    _ = libc.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, @sizeOf(timeval));
}

/// Half-close both directions of a socket so a peer/owner thread blocked in `read`
/// wakes (returns 0) and cleans up. Unlike close(), it does not free the fd number, so
/// it is safe to call on a socket another thread still owns (no fd-reuse race).
pub fn shutdownRdwr(fd: c_int) void {
    _ = libc.shutdown(fd, 2); // SHUT_RDWR (2 on macOS and Linux)
}

/// Half-close only the READ side (SHUT_RD = 0 on macOS and Linux): a blocked poll/read wakes
/// with EOF, but the WRITE side stays open so any buffered tail can still be delivered. Used
/// for a graceful guest close so the delivery ring flushes losslessly before the fd closes.
pub fn shutdownRd(fd: c_int) void {
    _ = libc.shutdown(fd, 0);
}

/// Non-blocking partial send: returns the bytes accepted (0 on EAGAIN or error). Requires
/// the fd to be O_NONBLOCK (setNonblock) - on macOS AF_UNIX, MSG_DONTWAIT alone is NOT
/// honored. Used by the data-plane bridge to deliver without ever blocking the vCPU thread.
pub fn trySend(fd: c_int, buf: []const u8) usize {
    if (buf.len == 0) return 0;
    const MSG_DONTWAIT: c_int = if (builtin.os.tag == .macos) 0x80 else 0x40;
    const n = libc.send(fd, buf.ptr, buf.len, MSG_DONTWAIT);
    return if (n > 0) @intCast(n) else 0;
}

/// Enlarge a socket's send buffer so brief reader lag doesn't immediately fail a
/// non-blocking send. BSD/macOS + Linux socket-option values.
pub fn setSendBuf(fd: c_int, bytes: c_int) void {
    const SOL_SOCKET: c_int = if (builtin.os.tag == .macos) 0xffff else 1;
    const SO_SNDBUF: c_int = if (builtin.os.tag == .macos) 0x1001 else 7;
    _ = libc.setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bytes, @sizeOf(c_int));
}

/// Put `fd` in non-blocking mode (O_NONBLOCK). macOS honors this on AF_UNIX where
/// MSG_DONTWAIT alone does NOT; pair it with pollRW for reads/writes.
pub fn setNonblock(fd: c_int) void {
    const F_GETFL: c_int = 3;
    const F_SETFL: c_int = 4;
    const O_NONBLOCK: c_int = if (builtin.os.tag == .macos) 0x0004 else 0o4000;
    const fl = libc.fcntl(fd, F_GETFL, @as(c_int, 0));
    if (fl >= 0) _ = libc.fcntl(fd, F_SETFL, @as(c_int, fl | O_NONBLOCK));
}

pub const Pollfd = extern struct { fd: c_int, events: i16, revents: i16 };
const POLLIN: i16 = 0x001;
const POLLOUT: i16 = 0x004;
const POLLERR: i16 = 0x008;
const POLLHUP: i16 = 0x010;
const POLLNVAL: i16 = 0x020;

/// Wait up to `timeout_ms` for `fd`. Also polls writability when `want_write`. Returns a
/// bitmask: bit0 (1) = readable, bit1 (2) = writable; 0 = timeout; -1 = hangup/error.
/// poll flag values are identical on macOS and Linux.
pub fn pollRW(fd: c_int, want_write: bool, timeout_ms: c_int) i32 {
    var p = Pollfd{ .fd = fd, .events = POLLIN | (if (want_write) POLLOUT else 0), .revents = 0 };
    const r = libc.poll(&p, 1, timeout_ms);
    if (r < 0) return -1;
    if (r == 0) return 0;
    if (p.revents & (POLLHUP | POLLERR | POLLNVAL) != 0) return -1;
    var res: i32 = 0;
    if (p.revents & POLLIN != 0) res |= 1;
    if (p.revents & POLLOUT != 0) res |= 2;
    return res;
}

/// Ignore SIGPIPE process-wide so a `write` to a control client that disconnected
/// mid-stream returns EPIPE (handled by `writeAll` returning false) instead of the
/// default action - terminating the whole sandbox process. A control-client disconnect
/// must never kill the guest. Called once when the control plane starts; idempotent.
pub fn ignoreSigpipe() void {
    const SIGPIPE: c_int = 13;
    const SIG_IGN: usize = 1;
    _ = libc.signal(SIGPIPE, SIG_IGN);
}
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
// ru_maxrss is the 3rd field (offset 2*sizeof(timeval) = 32 on both ABIs), a `long`.
// UNITS DIFFER: bytes on macOS, kilobytes on Linux - converted to MB per-OS below.
const Rusage = extern struct {
    utime: RuTimeval = .{},
    stime: RuTimeval = .{},
    maxrss: i64 = 0,
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

/// Peak resident memory of the whole nether process, in MB. The guest's RAM is a host
/// mmap, so pages the guest touches fault in and count toward RSS - this is the
/// sandbox's actual memory high-water mark (vs ram_mb, which is only the cap). ru_maxrss
/// is bytes on macOS, kilobytes on Linux; both normalized to MB.
pub fn processMaxRssMb() u64 {
    var ru: Rusage = .{};
    if (getrusage(0, &ru) != 0) return 0; // RUSAGE_SELF = 0
    if (ru.maxrss <= 0) return 0;
    const rss: u64 = @intCast(ru.maxrss);
    return if (builtin.os.tag == .macos) rss / (1024 * 1024) else rss / 1024;
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
    return readFileFd(allocator, fd);
}

/// Read a whole ALREADY-OPEN file into a freshly allocated buffer (caller frees; the
/// fd stays owned by the caller). Split out of readFileMac so a caller that opened via
/// openJailedAt (a TOCTOU-safe open) can reuse the exact same read/short-read logic.
pub fn readFileFd(allocator: std.mem.Allocator, fd: c_int) ![]u8 {
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

/// Open a path for create + truncate WRITE, refusing to follow a symlink at the final
/// component (O_NOFOLLOW). Used for host-mediated writes confined to the transfer jail
/// (`__get__`, `__snapshot__`): jailedPath confirms the path string is inside the jail but
/// only realpath's the PARENT dir, so a pre-existing symlink AT the basename could still
/// redirect the write outside the jail. O_NOFOLLOW closes that hole race-free - the final
/// open itself refuses a symlink (ELOOP) rather than an lstat check that could TOCTOU.
/// oflag bit values differ between BSD/macOS and Linux; selected at comptime so the KVM
/// path gets real O_CREAT + O_NOFOLLOW (mis-decoded macOS bits there would drop both,
/// breaking __get__ with ENOENT and silently disabling the symlink defense). Returns the
/// fd, or -1.
pub fn createTruncNoFollow(path: [*:0]const u8) c_int {
    const flags = if (builtin.os.tag == .macos) .{
        .WRONLY = 0x0001,
        .CREAT = 0x0200,
        .TRUNC = 0x0400,
        .NOFOLLOW = 0x0100,
    } else .{ // Linux (asm-generic)
        .WRONLY = 0o000001,
        .CREAT = 0o000100,
        .TRUNC = 0o001000,
        .NOFOLLOW = 0o400000,
    };
    // 0o600: a guest file pulled to the host jail (or a written snapshot) is owner-only, not
    // world-readable - the transfer is confined to the owner-uid-gated socket, so its output
    // should not leak to other local users.
    return libc.open(path, flags.WRONLY | flags.CREAT | flags.TRUNC | flags.NOFOLLOW, @as(c_int, 0o600));
}

/// Open a path INSIDE a jail with no check-to-use gap: walk `rel` (a path relative to
/// the pinned jail-root dirfd) component-by-component, opening every intermediate
/// directory with O_NOFOLLOW|O_DIRECTORY relative to the previous component's fd, and
/// the final component with O_NOFOLLOW (create+trunc-write when `create`, else read).
///
/// This closes the transfer-path TOCTOU (audit P2 #2): jailedPath realpath-resolves a
/// path and the caller opens it LATER, so a same-uid attacker who swaps an intermediate
/// directory for a symlink between the two escapes the jail. Here every step resolves
/// relative to an fd of the directory actually opened - a swapped component is either
/// not followed (symlink -> ELOOP via O_NOFOLLOW) or changes nothing (the dirfd already
/// pins the real directory), so the returned fd is provably under the jail root.
/// `rel` must be relative and canonical-ish: empty, absolute, "." or ".." components
/// are rejected fail-closed (jailedPath output converted by the caller satisfies this).
/// Files are created 0600 like createTruncNoFollow. Returns the fd, or -1.
pub fn openJailedAt(root_fd: c_int, rel: []const u8, create: bool) c_int {
    if (root_fd < 0 or rel.len == 0 or rel[0] == '/') return -1;
    const flags = if (builtin.os.tag == .macos) .{
        .WRONLY = 0x0001,
        .CREAT = 0x0200,
        .TRUNC = 0x0400,
        .NOFOLLOW = 0x0100,
        .DIRECTORY = 0x100000,
    } else .{ // Linux (asm-generic)
        .WRONLY = 0o000001,
        .CREAT = 0o000100,
        .TRUNC = 0o001000,
        .NOFOLLOW = 0o400000,
        .DIRECTORY = 0o200000,
    };
    var dirfd = root_fd;
    var owned = false; // dirfd is ours to close (never the caller's root_fd)
    var it = std.mem.splitScalar(u8, rel, '/');
    var comp = it.next() orelse return -1;
    while (true) {
        const next = it.next();
        var cb: [256]u8 = undefined; // one component; NAME_MAX is 255 on macOS and Linux
        const bad = comp.len == 0 or std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..");
        const compz = if (bad) null else cpath(&cb, comp);
        if (compz == null) {
            if (owned) _ = libc.close(dirfd);
            return -1;
        }
        if (next == null) { // final component: the file itself
            const oflag: c_int = if (create)
                flags.WRONLY | flags.CREAT | flags.TRUNC | flags.NOFOLLOW
            else
                flags.NOFOLLOW; // O_RDONLY is 0
            const fd = libc.openat(dirfd, compz.?, oflag, @as(c_int, 0o600));
            if (owned) _ = libc.close(dirfd);
            return fd;
        }
        // Intermediate: must be a real directory reached without following a symlink.
        const nd = libc.openat(dirfd, compz.?, flags.NOFOLLOW | flags.DIRECTORY, @as(c_int, 0));
        if (owned) _ = libc.close(dirfd);
        if (nd < 0) return -1;
        dirfd = nd;
        owned = true;
        comp = next.?;
    }
}

/// Flush a MAP_SHARED mapping (a persistent virtio-blk disk) to its backing file, so a
/// guest fsync -> virtio FLUSH is durable even against a hard guest poweroff. MS_SYNC
/// differs by OS; the HVF host is macOS.
pub fn syncMapping(buf: []u8) void {
    const MS_SYNC: c_int = if (builtin.os.tag == .macos) 0x10 else 4;
    _ = libc.msync(buf.ptr, buf.len, MS_SYNC);
}

/// Copy a path slice into `buf` as a NUL-terminated C string for libc calls.
pub fn cpath(buf: []u8, p: []const u8) ?[*:0]const u8 {
    if (p.len + 1 > buf.len) return null;
    @memcpy(buf[0..p.len], p);
    buf[p.len] = 0;
    return @ptrCast(buf.ptr);
}

test "openJailedAt walks components openat/O_NOFOLLOW and rejects symlinked escapes" {
    const c = struct {
        extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
        extern "c" fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) c_int;
        extern "c" fn rmdir(path: [*:0]const u8) c_int;
        extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
    };
    const jail = "/tmp/nether-openat-jail";
    const outside = "/tmp/nether-openat-outside";
    // Layout: jail/sub/file.txt (legit), outside/file.txt (the escape target),
    // jail/evil -> /etc/hosts (symlink at the basename).
    inline for (.{ jail ++ "/sub/file.txt", jail ++ "/evil", outside ++ "/file.txt" }) |f| _ = libc.unlink(f);
    inline for (.{ jail ++ "/sub", jail, outside }) |d| _ = c.rmdir(d);
    if (c.mkdir(jail, 0o700) != 0) return error.SkipZigTest;
    if (c.mkdir(jail ++ "/sub", 0o700) != 0) return error.SkipZigTest;
    if (c.mkdir(outside, 0o700) != 0) return error.SkipZigTest;
    defer {
        inline for (.{ jail ++ "/sub/file.txt", jail ++ "/evil", outside ++ "/file.txt" }) |f| _ = libc.unlink(f);
        inline for (.{ jail ++ "/sub", jail, outside }) |d| _ = c.rmdir(d);
    }
    const O_DIRECTORY: c_int = if (builtin.os.tag == .macos) 0x100000 else 0o200000;
    const root_fd = libc.open(jail, O_DIRECTORY, @as(c_int, 0));
    try std.testing.expect(root_fd >= 0);
    defer _ = libc.close(root_fd);

    // Create through the walker, then read it back through the walker.
    const wfd = openJailedAt(root_fd, "sub/file.txt", true);
    try std.testing.expect(wfd >= 0);
    try std.testing.expect(writeAll(wfd, "JAILDATA"));
    _ = libc.close(wfd);
    const rfd = openJailedAt(root_fd, "sub/file.txt", false);
    try std.testing.expect(rfd >= 0);
    const data = try readFileFd(std.testing.allocator, rfd);
    defer std.testing.allocator.free(data);
    _ = libc.close(rfd);
    try std.testing.expectEqualStrings("JAILDATA", data);

    // The TOCTOU move: swap the intermediate `sub` for a symlink to a directory
    // OUTSIDE the jail (what an attacker does between realpath and open). The walker
    // must refuse to traverse it (O_NOFOLLOW on the intermediate -> ELOOP).
    try std.testing.expect(c.rename(jail ++ "/sub", jail ++ "/sub-real") == 0);
    defer {
        _ = libc.unlink(jail ++ "/sub");
        _ = c.rename(jail ++ "/sub-real", jail ++ "/sub");
    }
    try std.testing.expect(c.symlink(outside, jail ++ "/sub") == 0);
    try std.testing.expect(openJailedAt(root_fd, "sub/file.txt", false) < 0); // read escape refused
    try std.testing.expect(openJailedAt(root_fd, "sub/file.txt", true) < 0); // create escape refused
    try std.testing.expect(libc.open(outside ++ "/file.txt", 0, @as(c_int, 0)) < 0); // nothing was created outside

    // A symlink at the BASENAME is refused in both modes (same O_NOFOLLOW discipline).
    _ = c.symlink("/etc/hosts", jail ++ "/evil");
    try std.testing.expect(openJailedAt(root_fd, "evil", false) < 0);
    try std.testing.expect(openJailedAt(root_fd, "evil", true) < 0);

    // Malformed rel paths fail closed: empty, absolute, dot/dotdot, empty component.
    try std.testing.expect(openJailedAt(root_fd, "", false) < 0);
    try std.testing.expect(openJailedAt(root_fd, "/etc/hosts", false) < 0);
    try std.testing.expect(openJailedAt(root_fd, "../escape.txt", true) < 0);
    try std.testing.expect(openJailedAt(root_fd, "sub-real/../file.txt", true) < 0);
    try std.testing.expect(openJailedAt(root_fd, "sub-real//file.txt", true) < 0);
    try std.testing.expect(openJailedAt(root_fd, "./file.txt", true) < 0);
    try std.testing.expect(openJailedAt(-1, "x", false) < 0); // no pinned root -> fail closed
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

test "processMaxRssMb reports a plausible resident footprint" {
    // The test process is resident, so peak RSS is positive; the per-OS unit
    // conversion (bytes on macOS, KB on Linux) must land in a sane MB range, not the
    // raw bytes/KB value (which would be absurdly large if the units were mishandled).
    const mb = processMaxRssMb();
    try std.testing.expect(mb > 0);
    try std.testing.expect(mb < 1024 * 1024); // < 1 TiB: catches a units mistake
}
