//! ARM PL031 PrimeCell RTC (MMIO), the "virt" board's real-time clock. Without it a
//! Nether guest has no wall clock and boots at the epoch (1970); the guest kernel's
//! rtc-pl031 driver reads this device at boot and sets CLOCK_REALTIME (rtc-hctosys), so
//! the guest learns the real time.
//!
//! It is also the guest's WALL-CLOCK CATCH-UP across a park: the data register returns
//! LIVE host wall time, so a snapshot-forked guest whose CLOCK_REALTIME froze at the park
//! moment reads the (advanced) real time here and reconciles with `hwclock -s`. The
//! monotonic clock stays continuous (that is the vtimer's job); this device is only the
//! wall clock, which SHOULD jump forward to real time after a long park.
//!
//! Registers follow the PL031 TRM at the offsets Linux's rtc-pl031 driver expects,
//! including the AMBA PrimeCell ID registers at 0xFE0-0xFFC so the driver's bus match
//! (peripheral id 0x00041031) succeeds. The device is host-clock-backed and effectively
//! stateless: a load (RTCLR) sets an offset so `hwclock -w` round-trips within a session,
//! but the offset is NOT snapshotted - a fork reads live host time, which is the point.

const std = @import("std");
const io = @import("io.zig");
const hostutil = @import("../common/hostutil.zig");

pub const Pl031 = struct {
    // Offset applied to host time, set via RTCLR (so a guest that writes the clock is
    // consistent within its session). Starts 0 => the data register reads real host time.
    offset: i32 = 0,
    match: u32 = 0, // RTCMR alarm target (stored; no alarm interrupt is asserted)
    cr: u32 = 0, // RTCCR (control)
    imsc: u32 = 0, // interrupt mask (stored; the alarm is never raised)

    const DR = 0x000; // data register (RO): current time, seconds since the epoch
    const MR = 0x004; // match register (alarm)
    const LR = 0x008; // load register (WO): set the counter
    const CR = 0x00C; // control register
    const IMSC = 0x010; // interrupt mask set/clear
    const RIS = 0x014; // raw interrupt status
    const MIS = 0x018; // masked interrupt status
    const ICR = 0x01C; // interrupt clear
    const PERIPH_ID0 = 0xFE0;
    const PCELL_ID0 = 0xFF0;

    // AMBA ids: peripheral 0x00041031 (part 031 = PL031, designer ARM), PrimeCell
    // 0xB105F00D. One byte per 4-byte word, little-endian, as the driver reads them.
    const periph_id = [4]u8{ 0x31, 0x10, 0x04, 0x00 };
    const pcell_id = [4]u8{ 0x0D, 0xF0, 0x05, 0xB1 };

    pub fn device(self: *Pl031, base: u64) io.MmioDevice {
        return .{ .ptr = self, .base = base, .len = 0x1000, .read_fn = readThunk, .write_fn = writeThunk };
    }

    /// Host wall-clock seconds since the epoch (the live value the data register serves).
    fn hostSeconds() i64 {
        return @divTrunc(hostutil.nowMs(), 1000);
    }

    fn reg(self: *Pl031, offset: u64) u32 {
        return switch (offset) {
            DR => @truncate(@as(u64, @bitCast(hostSeconds() + self.offset))),
            MR => self.match,
            CR => self.cr,
            IMSC => self.imsc,
            RIS, MIS => 0, // the alarm is never asserted, so no interrupt is ever pending
            PERIPH_ID0, PERIPH_ID0 + 4, PERIPH_ID0 + 8, PERIPH_ID0 + 12 => periph_id[(offset - PERIPH_ID0) / 4],
            PCELL_ID0, PCELL_ID0 + 4, PCELL_ID0 + 8, PCELL_ID0 + 12 => pcell_id[(offset - PCELL_ID0) / 4],
            else => 0,
        };
    }

    fn readThunk(ptr: *anyopaque, offset: u64, data: []u8) void {
        const self: *Pl031 = @ptrCast(@alignCast(ptr));
        @memset(data, 0);
        const v: u32 = self.reg(offset);
        for (data, 0..) |*b, i| {
            if (i < 4) b.* = @truncate(v >> @intCast(i * 8));
        }
    }

    fn writeThunk(ptr: *anyopaque, offset: u64, data: []const u8) void {
        const self: *Pl031 = @ptrCast(@alignCast(ptr));
        const v = leValue(data);
        switch (offset) {
            LR => self.offset = @as(i32, @bitCast(v)) -% @as(i32, @truncate(hostSeconds())), // set counter -> offset from host time
            MR => self.match = v,
            CR => self.cr = v,
            IMSC => self.imsc = v,
            ICR => {}, // clearing an interrupt that is never raised
            else => {},
        }
    }

    fn leValue(data: []const u8) u32 {
        var v: u32 = 0;
        for (data, 0..) |b, i| {
            if (i < 4) v |= @as(u32, b) << @intCast(i * 8);
        }
        return v;
    }
};

const testing = std.testing;

test "pl031 data register serves host wall time and advertises the PL031 primecell id" {
    var rtc = Pl031{};
    const dev = rtc.device(0x0901_0000);
    // The data register reads back ~host wall time (non-zero, and within a second of it).
    var dr: [4]u8 = undefined;
    dev.read_fn(dev.ptr, 0x000, &dr);
    const read: u32 = @as(u32, dr[0]) | (@as(u32, dr[1]) << 8) | (@as(u32, dr[2]) << 16) | (@as(u32, dr[3]) << 24);
    const now: u32 = @truncate(@as(u64, @bitCast(@divTrunc(hostutil.nowMs(), 1000))));
    try testing.expect(read != 0);
    try testing.expect(now -% read <= 2); // within 2s of host time

    // The AMBA peripheral id must decode to 0x00041031 so rtc-pl031 binds.
    var id: u32 = 0;
    inline for (0..4) |i| {
        var w: [4]u8 = undefined;
        dev.read_fn(dev.ptr, 0xFE0 + i * 4, &w);
        id |= @as(u32, w[0]) << @intCast(i * 8);
    }
    try testing.expectEqual(@as(u32, 0x0004_1031), id);

    // A load offsets the counter: write "now + 1000", read back ~now + 1000.
    var lr: [4]u8 = undefined;
    const target: u32 = read +% 1000;
    inline for (0..4) |i| lr[i] = @truncate(target >> @intCast(i * 8));
    dev.write_fn(dev.ptr, 0x008, &lr);
    dev.read_fn(dev.ptr, 0x000, &dr);
    const after: u32 = @as(u32, dr[0]) | (@as(u32, dr[1]) << 8) | (@as(u32, dr[2]) << 16) | (@as(u32, dr[3]) << 24);
    try testing.expect(after -% read >= 999 and after -% read <= 1002);
}
