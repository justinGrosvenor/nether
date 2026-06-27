//! ACPI PM block (fixed hardware). Handles S5 soft-off via PM1a_CNT and serves
//! the ACPI power-management timer. The base port is reported to the guest via
//! the FADT (added with ACPI later); for now it is fixed.

const std = @import("std");
const linux = std.os.linux;
const io = @import("io.zig");
const pwr = @import("common/power.zig");

pub const Pm = struct {
    power: *pwr.Power,
    pm1_status: u16 = 0,
    pm1_enable: u16 = 0,
    pm1_control: u16 = 0,

    pub const base = 0x600;
    const len = 0x0c;

    const off_status = 0; // PM1a_EVT_BLK status word
    const off_enable = 2; // PM1a_EVT_BLK enable word
    const off_control = 4; // PM1a_CNT_BLK
    const off_timer = 8; // PM_TMR_BLK

    const slp_en: u16 = 1 << 13;
    const s5_typ: u16 = 5; // _S5 SLP_TYP, matches our DSDT

    pub fn device(self: *Pm) io.PioDevice {
        return .{ .ptr = self, .base = base, .len = len, .out_fn = onOut, .in_fn = onIn };
    }

    fn onOut(ptr: *anyopaque, p: u16, size: u8, value: u32) void {
        _ = size;
        const self: *Pm = @ptrCast(@alignCast(ptr));
        switch (p - base) {
            off_status => self.pm1_status = @truncate(value),
            off_enable => self.pm1_enable = @truncate(value),
            off_control => {
                const v: u16 = @truncate(value);
                self.pm1_control = v;
                if (v & slp_en != 0 and (v >> 10) & 0x7 == s5_typ) {
                    self.power.request(.shutdown);
                }
            },
            else => {},
        }
    }

    fn onIn(ptr: *anyopaque, p: u16, size: u8) u32 {
        _ = size;
        const self: *Pm = @ptrCast(@alignCast(ptr));
        return switch (p - base) {
            off_status => self.pm1_status,
            off_enable => self.pm1_enable,
            off_control => self.pm1_control,
            off_timer => pmTimer(),
            else => 0,
        };
    }
};

/// ACPI PM timer: 24-bit counter at 3.579545 MHz, derived from the host
/// monotonic clock.
const pm_tmr_hz = 3_579_545;

fn pmTimer() u32 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    const ns: u128 = @as(u128, @intCast(ts.sec)) * 1_000_000_000 + @as(u128, @intCast(ts.nsec));
    return pmTicks(ns);
}

fn pmTicks(ns: u128) u32 {
    const ticks = ns * pm_tmr_hz / 1_000_000_000;
    return @as(u32, @truncate(ticks)) & 0xFF_FFFF;
}

test "pm timer is 24-bit and advances" {
    try std.testing.expectEqual(@as(u32, 0), pmTicks(0));
    const ms1 = pmTicks(1_000_000); // +1ms is ~3579 ticks
    try std.testing.expect(ms1 > 0 and ms1 <= 0xFF_FFFF);
    // Stays masked to 24 bits over long spans.
    try std.testing.expect(pmTicks(1_000_000_000_000_000) <= 0xFF_FFFF);
}
