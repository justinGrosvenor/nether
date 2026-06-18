//! MC146818 RTC/CMOS at ports 0x70 (index) / 0x71 (data). Serves wall-clock
//! time (UTC, BCD, 24-hour) from the host plus a small CMOS RAM scratch. Part of
//! the firmware floor: OVMF reads the RTC at boot.

const std = @import("std");
const linux = std.os.linux;
const io = @import("io.zig");

pub const Rtc = struct {
    index: u8 = 0,
    ram: [128]u8 = [_]u8{0} ** 128,

    const idx_port = 0x70;
    const data_port = 0x71;

    const reg_seconds = 0x00;
    const reg_minutes = 0x02;
    const reg_hours = 0x04;
    const reg_weekday = 0x06;
    const reg_day = 0x07;
    const reg_month = 0x08;
    const reg_year = 0x09;
    const reg_status_a = 0x0A;
    const reg_status_b = 0x0B;
    const reg_status_c = 0x0C;
    const reg_status_d = 0x0D;
    const reg_century = 0x32;

    pub fn device(self: *Rtc) io.PioDevice {
        return .{ .ptr = self, .base = idx_port, .len = 2, .out_fn = onOut, .in_fn = onIn };
    }

    fn onOut(ptr: *anyopaque, p: u16, size: u8, value: u32) void {
        _ = size;
        const self: *Rtc = @ptrCast(@alignCast(ptr));
        if (p == idx_port) {
            self.index = @as(u8, @truncate(value)) & 0x7F; // top bit is NMI mask, ignored
        } else {
            self.ram[self.index] = @truncate(value);
        }
    }

    fn onIn(ptr: *anyopaque, p: u16, size: u8) u32 {
        _ = size;
        const self: *Rtc = @ptrCast(@alignCast(ptr));
        if (p == idx_port) return 0xFF; // index port is not readable
        const t = nowUtc();
        return switch (self.index) {
            reg_seconds => bcd(t.sec),
            reg_minutes => bcd(t.min),
            reg_hours => bcd(t.hour),
            reg_weekday => bcd(t.wday),
            reg_day => bcd(t.mday),
            reg_month => bcd(t.month),
            reg_year => bcd(t.year2),
            reg_century => bcd(t.century),
            reg_status_a => 0x26, // 32kHz time base, no update in progress
            reg_status_b => 0x02, // 24-hour mode, BCD
            reg_status_c => 0x00,
            reg_status_d => 0x80, // RAM/battery valid
            else => self.ram[self.index],
        };
    }
};

fn bcd(v: u8) u32 {
    return (@as(u32, v / 10) << 4) | (v % 10);
}

const Wall = struct {
    sec: u8,
    min: u8,
    hour: u8,
    wday: u8, // CMOS weekday, Sunday = 1
    mday: u8,
    month: u8,
    year2: u8,
    century: u8,
};

fn nowUtc() Wall {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.REALTIME, &ts);
    return decode(@intCast(ts.sec));
}

fn decode(secs: u64) Wall {
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const ds = es.getDaySeconds();
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const year: u16 = yd.year;
    // 1970-01-01 was a Thursday (index 4 with Sunday = 0).
    const wday: u8 = @intCast((ed.day + 4) % 7 + 1);
    return .{
        .sec = ds.getSecondsIntoMinute(),
        .min = ds.getMinutesIntoHour(),
        .hour = ds.getHoursIntoDay(),
        .wday = wday,
        .mday = @as(u8, md.day_index) + 1,
        .month = md.month.numeric(),
        .year2 = @intCast(year % 100),
        .century = @intCast(year / 100),
    };
}

test "decode a known epoch" {
    // 2021-01-01 00:00:00 UTC = 1609459200, a Friday.
    const w = decode(1609459200);
    try std.testing.expectEqual(@as(u8, 0), w.sec);
    try std.testing.expectEqual(@as(u8, 0), w.hour);
    try std.testing.expectEqual(@as(u8, 1), w.mday);
    try std.testing.expectEqual(@as(u8, 1), w.month);
    try std.testing.expectEqual(@as(u8, 21), w.year2);
    try std.testing.expectEqual(@as(u8, 20), w.century);
    try std.testing.expectEqual(@as(u8, 6), w.wday); // Friday -> CMOS 6 (Sun = 1)
}

test "bcd encodes decimal digits" {
    try std.testing.expectEqual(@as(u32, 0x59), bcd(59));
    try std.testing.expectEqual(@as(u32, 0x00), bcd(0));
    try std.testing.expectEqual(@as(u32, 0x23), bcd(23));
}
