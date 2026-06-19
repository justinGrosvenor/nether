//! Device bring-up tracing. Enabled at startup if a file named `nether-trace`
//! exists in the working directory (so it toggles per-run with no rebuild and no
//! env/args machinery). Trace points on the PCI config, virtio transport, and
//! MSI paths make a hanging device-bringup debuggable: you watch the guest
//! driver probe config space, size the BAR, negotiate features, set up the
//! queue, kick, and whether our MSI fires.

const std = @import("std");
const linux = std.os.linux;

var enabled: bool = false;

pub fn init() void {
    const fd = linux.open("nether-trace", .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) == .SUCCESS) {
        enabled = true;
        _ = linux.close(@intCast(fd));
    }
}

pub fn on() bool {
    return enabled;
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (enabled) std.debug.print("[trace] " ++ fmt ++ "\n", args);
}
