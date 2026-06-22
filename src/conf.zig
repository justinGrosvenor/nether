//! Per-sandbox launch configuration: a minimal `nether.conf` (`key = value` lines,
//! `#` comments) the platform writes per sandbox, plus the legacy marker-file modes.
//! The platform writes one config per sandbox (e.g. a distinct `control_socket`
//! path) so many sandboxes run on one host.

const std = @import("std");
const libc = @import("hostutil.zig").libc;

/// Read a `key=value` from `nether.conf` in the cwd into `out` (NUL-terminated for
/// socket binds), returning the value or null if the file/key is absent.
pub fn confGet(key: []const u8, out: []u8) ?[]const u8 {
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
pub fn confGetInt(key: []const u8, default: u64) u64 {
    var b: [32]u8 = undefined;
    if (confGet(key, &b)) |v| return std.fmt.parseInt(u64, v, 10) catch default;
    return default;
}

/// nether.conf boolean (`1`/`true`/`yes`) for `key`, false if absent.
pub fn confBool(key: []const u8) bool {
    var b: [16]u8 = undefined;
    if (confGet(key, &b)) |v| {
        return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "yes");
    }
    return false;
}

/// True if `path` exists (the legacy marker-file mechanism).
pub fn markerPresent(path: [*:0]const u8) bool {
    const fd = libc.open(path, 0, @as(c_int, 0));
    if (fd < 0) return false;
    _ = libc.close(fd);
    return true;
}

/// A mode is on if its config key is set or its (legacy) marker file is present.
pub fn modeOn(comptime conf_key: []const u8, comptime marker: [*:0]const u8) bool {
    return confBool(conf_key) or markerPresent(marker);
}
