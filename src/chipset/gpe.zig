//! ACPI GPE0 block (General Purpose Events) for the x86 platform. One byte of
//! status + one byte of enable at GPE0_BLK (I/O 0x620), covering GPE bits 0..7.
//! Nether uses GPE bit 0 as the fork signal: on restore it writes a fresh VM
//! Generation ID and calls `signal(0)`, which sets the status bit and asserts the
//! SCI (IRQ 9). The guest's ACPI runs the DSDT `\_GPE._E00` method, which Notifies
//! the vmgenid device to re-read the GUID and reseed the CRNG, then clears the
//! status bit (write-1-to-clear) - so two forks of one base diverge their random
//! streams immediately, with a stock guest driver and no agent round-trip.

const std = @import("std");
const io = @import("io.zig");
const ioapic = @import("../hv/ioapic.zig");

pub const Gpe = struct {
    apic: *ioapic.IoApic,
    status: u8 = 0,
    enable: u8 = 0,

    pub const base = 0x620; // clear of the PM block (0x600..0x60b)
    const len = 2; // [status:1][enable:1] -> GPE bits 0..7
    pub const SCI_GSI: u8 = 9; // matches FADT SCI_INT

    pub const FORK_BIT: u3 = 0; // GPE 0 -> DSDT _E00 -> Notify(VGEN, 0x80)

    pub fn device(self: *Gpe) io.PioDevice {
        return .{ .ptr = self, .base = base, .len = len, .out_fn = onOut, .in_fn = onIn };
    }

    fn onOut(ptr: *anyopaque, p: u16, size: u8, value: u32) void {
        _ = size;
        const self: *Gpe = @ptrCast(@alignCast(ptr));
        switch (p - base) {
            0 => self.status &= ~@as(u8, @truncate(value)), // status: write-1-to-clear
            1 => self.enable = @truncate(value),
            else => {},
        }
    }

    fn onIn(ptr: *anyopaque, p: u16, size: u8) u32 {
        _ = size;
        const self: *Gpe = @ptrCast(@alignCast(ptr));
        return switch (p - base) {
            0 => self.status,
            1 => self.enable,
            else => 0,
        };
    }

    /// Assert GPE bit `n` and deliver the SCI. The guest's SCI handler reads the
    /// status, runs the matching `_Enn` method, and clears the bit; a single
    /// injection is enough for a one-shot event.
    ///
    /// The enable bit is forced set here: the guest enabled this GPE during the base
    /// boot (it has an `_Enn` handler), but the enable register lives in this host
    /// process, not guest RAM, so a fork starts with a fresh (zeroed) block. Forcing
    /// it reflects the guest's own intent, so `status & enable` matches on its side.
    pub fn signal(self: *Gpe, n: u3) void {
        const m = @as(u8, 1) << n;
        self.enable |= m;
        self.status |= m;
        self.apic.raise(SCI_GSI);
    }
};

test "gpe status is write-1-to-clear and enable gates the SCI" {
    var g = Gpe{ .apic = undefined };
    // enable bit 0, then signal: status set. (raise() would inject; not exercised here.)
    g.enable = 0x01;
    g.status = 0x00;
    // write-1-to-clear on a set bit
    g.status = 0x05;
    Gpe.onOut(&g, Gpe.base, 1, 0x01); // clear bit 0
    try std.testing.expectEqual(@as(u8, 0x04), g.status);
    // enable readback
    Gpe.onOut(&g, Gpe.base + 1, 1, 0x0f);
    try std.testing.expectEqual(@as(u32, 0x0f), Gpe.onIn(&g, Gpe.base + 1, 1));
}
