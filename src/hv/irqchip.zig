//! Split irqchip and eventfd plumbing.
//!
//! Split irqchip means the LAPIC runs in-kernel while the IOAPIC and PIC are
//! left to userspace (decisions.md D6). This module enables that and provides
//! the eventfd machinery the I/O thread uses:
//!
//!   - irqfd:    signaling an eventfd injects an interrupt at a GSI.
//!   - ioeventfd: a guest write to an address signals an eventfd instead of
//!                exiting to userspace (the fast notification path).
//!   - signalMsi: inject an MSI directly, no routing-table entry needed.
//!
//! Not yet here: the userspace IOAPIC itself (redirection table, EOI handling)
//! and KVM_SET_GSI_ROUTING for MSI-over-irqfd. Those land when a guest first
//! programs the IOAPIC (OVMF) or virtio-pci needs MSI-X routing.

const std = @import("std");
const linux = std.os.linux;
const kvm = @import("../hv/kvm.zig");
const trace = @import("../common/trace.zig");

pub const Error = error{SyscallFailed} || kvm.Error;

fn sys(r: usize, comptime what: []const u8) Error!usize {
    return switch (linux.errno(r)) {
        .SUCCESS => r,
        else => |e| {
            std.debug.print("[nether] {s} failed: {s}\n", .{ what, @tagName(e) });
            return error.SyscallFailed;
        },
    };
}

/// Default number of GSIs routed to the (userspace) IOAPIC.
pub const default_gsis = 24;

/// Create a non-blocking, close-on-exec eventfd.
pub fn eventfd() Error!i32 {
    const r = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    return @intCast(try sys(r, "eventfd"));
}

/// Enable the split irqchip: in-kernel LAPIC, userspace IOAPIC/PIC. Must be
/// called before any vCPU is created.
pub fn enableSplit(vm_fd: i32, gsis: u32) Error!void {
    var cap = kvm.EnableCap{
        .cap = kvm.CAP_SPLIT_IRQCHIP,
        .flags = 0,
        .args = .{ gsis, 0, 0, 0 },
        .pad = [_]u8{0} ** 64,
    };
    _ = try kvm.ioctl(vm_fd, kvm.ENABLE_CAP, @intFromPtr(&cap));
}

/// Bind `efd` to `gsi`: signaling the eventfd injects that interrupt.
pub fn assignIrqfd(vm_fd: i32, efd: i32, gsi: u32) Error!void {
    var f = kvm.Irqfd{
        .fd = @intCast(efd),
        .gsi = gsi,
        .flags = 0,
        .resamplefd = 0,
        .pad = [_]u8{0} ** 16,
    };
    _ = try kvm.ioctl(vm_fd, kvm.IRQFD, @intFromPtr(&f));
}

pub const IoeventSpace = enum { mmio, pio };

/// Bind `efd` to a guest write at `addr` of `len` bytes: the write signals the
/// eventfd instead of exiting to userspace.
pub fn assignIoeventfd(vm_fd: i32, efd: i32, space: IoeventSpace, addr: u64, len: u32) Error!void {
    var e = kvm.Ioeventfd{
        .datamatch = 0,
        .addr = addr,
        .len = len,
        .fd = efd,
        .flags = if (space == .pio) kvm.IOEVENTFD_FLAG_PIO else 0,
        .pad = [_]u8{0} ** 36,
    };
    _ = try kvm.ioctl(vm_fd, kvm.IOEVENTFD, @intFromPtr(&e));
}

/// Inject an MSI directly from its address/data message.
pub fn signalMsi(vm_fd: i32, addr: u64, data: u32) Error!void {
    var m = kvm.Msi{
        .address_lo = @truncate(addr),
        .address_hi = @truncate(addr >> 32),
        .data = data,
        .flags = 0,
        .devid = 0,
        .pad = [_]u8{0} ** 12,
    };
    const r = try kvm.ioctl(vm_fd, kvm.SIGNAL_MSI, @intFromPtr(&m));
    trace.log("signalMsi r={d} addr=0x{x} data=0x{x}", .{ r, addr, data });
}
