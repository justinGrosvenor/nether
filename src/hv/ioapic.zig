//! Userspace I/O APIC (split irqchip owns it). The LAPIC is in-kernel, but with
//! KVM_CAP_SPLIT_IRQCHIP the IOAPIC and PIC are ours. Without it the guest reads
//! all-ones from 0xFEC00000 and disables legacy IRQ routing entirely, so serial
//! (IRQ4) interrupts never fire. This emulates the IOAPIC register file and, on
//! a device raising a GSI, translates the redirection entry into an MSI and
//! injects it via KVM (which delivers to the in-kernel LAPIC).

const std = @import("std");
const io = @import("../chipset/io.zig");
const memmap = @import("../mem/memmap.zig");
const irqchip = @import("../hv/irqchip.zig");
const trace = @import("../common/trace.zig");
const Lock = @import("../common/lock.zig").Lock;

pub const num_gsi = 24;

pub const IoApic = struct {
    vm_fd: i32 = -1,
    ioregsel: u8 = 0,
    id: u32 = 0,
    redir: [num_gsi]u64 = [_]u64{mask_bit} ** num_gsi, // masked until the guest programs them
    // The register file is written by the vCPU thread (guest MMIO) while devices
    // assert GSIs from both the vCPU thread (TX) and the host I/O thread (serial
    // RX), so the table is under `mutex` (the D3 per-device lock). Lock order is
    // always serial -> ioapic; raise() releases the lock before the MSI syscall.
    mutex: Lock = .{},

    pub const base = memmap.ioapic_base;
    const span = 0x20; // IOREGSEL at 0x00, IOWIN at 0x10
    const reg_id = 0x00;
    const reg_ver = 0x01;
    const reg_arb = 0x02;
    const reg_redir = 0x10;
    const mask_bit: u64 = 1 << 16;

    pub fn mmioDevice(self: *IoApic) io.MmioDevice {
        return .{ .ptr = self, .base = base, .len = span, .read_fn = onRead, .write_fn = onWrite };
    }

    fn onRead(ptr: *anyopaque, offset: u64, data: []u8) void {
        const self: *IoApic = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        const v: u32 = switch (offset) {
            0x00 => self.ioregsel,
            0x10 => self.readReg(self.ioregsel),
            else => 0,
        };
        putLE(data, v);
    }

    fn onWrite(ptr: *anyopaque, offset: u64, data: []const u8) void {
        const self: *IoApic = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (offset) {
            0x00 => self.ioregsel = @truncate(getLE(data)),
            0x10 => self.writeReg(self.ioregsel, getLE(data)),
            else => {},
        }
    }

    fn readReg(self: *IoApic, idx: u8) u32 {
        return switch (idx) {
            reg_id => self.id << 24,
            // version 0x11, max redirection entry index = num_gsi-1 in bits 16-23
            reg_ver => 0x11 | ((num_gsi - 1) << 16),
            reg_arb => self.id << 24,
            else => blk: {
                if (idx >= reg_redir and idx < reg_redir + num_gsi * 2) {
                    const n = (idx - reg_redir) / 2;
                    break :blk if ((idx - reg_redir) % 2 == 0)
                        @truncate(self.redir[n])
                    else
                        @truncate(self.redir[n] >> 32);
                }
                break :blk 0;
            },
        };
    }

    fn writeReg(self: *IoApic, idx: u8, val: u32) void {
        switch (idx) {
            reg_id => self.id = (val >> 24) & 0xff,
            else => {
                if (idx >= reg_redir and idx < reg_redir + num_gsi * 2) {
                    const n = (idx - reg_redir) / 2;
                    if ((idx - reg_redir) % 2 == 0) {
                        self.redir[n] = (self.redir[n] & 0xffffffff_00000000) | val;
                    } else {
                        self.redir[n] = (self.redir[n] & 0xffffffff) | (@as(u64, val) << 32);
                    }
                    trace.log("ioapic redir[{d}]=0x{x}", .{ n, self.redir[n] });
                }
            },
        }
    }

    /// A device asserted GSI `gsi`: translate its redirection entry to an MSI and
    /// inject it (no-op if masked).
    pub fn raise(self: *IoApic, gsi: u8) void {
        if (gsi >= num_gsi) return;
        self.mutex.lock();
        const e = self.redir[gsi];
        self.mutex.unlock();
        if (e & mask_bit != 0) return;
        const m = redirToMsi(e);
        trace.log("ioapic raise gsi={d} -> addr=0x{x} data=0x{x}", .{ gsi, m.addr, m.data });
        irqchip.signalMsi(self.vm_fd, m.addr, m.data) catch {};
    }

    /// LAPIC EOI for a level-triggered vector routed here: clear remote IRR.
    pub fn eoi(self: *IoApic, vector: u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.redir) |*e| {
            if (e.* & 0xff == vector and (e.* >> 15) & 1 == 1) {
                e.* &= ~(@as(u64, 1) << 14); // clear remote IRR
            }
        }
    }
};

const Msg = struct { addr: u64, data: u32 };

/// Translate an IOAPIC redirection entry into the equivalent MSI message.
fn redirToMsi(e: u64) Msg {
    const vector: u32 = @intCast(e & 0xff);
    const delivery: u32 = @intCast((e >> 8) & 0x7);
    const dest_mode: u64 = (e >> 11) & 1;
    const trigger: u32 = @intCast((e >> 15) & 1);
    const dest: u64 = (e >> 56) & 0xff;
    return .{
        .addr = 0xFEE00000 | (dest << 12) | (dest_mode << 2),
        .data = vector | (delivery << 8) | (trigger << 15) | (trigger << 14),
    };
}

fn putLE(data: []u8, value: u32) void {
    for (data, 0..) |*b, i| b.* = if (i < 4) @truncate(value >> @intCast(i * 8)) else 0;
}
fn getLE(data: []const u8) u32 {
    var v: u32 = 0;
    for (data, 0..) |b, i| {
        if (i < 4) v |= @as(u32, b) << @intCast(i * 8);
    }
    return v;
}

test "redirection register file round-trips via IOREGSEL/IOWIN" {
    var ia = IoApic{};
    const dev = ia.mmioDevice();
    // Program redir[4] low = vector 0x31, dest physical, unmasked; high dest=0.
    var buf = [_]u8{0} ** 4;
    putLE(&buf, 0x18); // IOREGSEL = redir[4] low (0x10 + 4*2)
    dev.write_fn(dev.ptr, 0x00, &buf);
    putLE(&buf, 0x31); // vector 0x31, edge, unmasked, fixed
    dev.write_fn(dev.ptr, 0x10, &buf);
    // Read it back.
    putLE(&buf, 0x18);
    dev.write_fn(dev.ptr, 0x00, &buf);
    dev.read_fn(dev.ptr, 0x10, &buf);
    try std.testing.expectEqual(@as(u32, 0x31), getLE(&buf));
}

test "version register advertises 24 redirection entries" {
    var ia = IoApic{};
    try std.testing.expectEqual(@as(u32, 0x11 | (23 << 16)), ia.readReg(0x01));
}

test "redirToMsi maps vector and destination" {
    // vector 0x30, fixed, physical, edge, dest 0
    const m0 = redirToMsi(0x30);
    try std.testing.expectEqual(@as(u64, 0xFEE00000), m0.addr);
    try std.testing.expectEqual(@as(u32, 0x30), m0.data);
    // dest 2 in bits 56-63
    const m2 = redirToMsi(0x30 | (@as(u64, 2) << 56));
    try std.testing.expectEqual(@as(u64, 0xFEE02000), m2.addr);
}

test "masked entry produces no delivery path" {
    var ia = IoApic{};
    // default entries are masked; raise should be a no-op (no crash, vm_fd -1)
    ia.raise(4);
    try std.testing.expect(ia.redir[4] & IoApic.mask_bit != 0);
}
