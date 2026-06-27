//! Reset control register (RST_CNT) at port 0xCF9. Writing bit 2 (SYS_RST)
//! initiates a platform reset. Part of the firmware floor: OVMF's ResetSystem
//! path pokes 0xCF9 despite the no-legacy stance, so it is irreducible.

const io = @import("../chipset/io.zig");
const pwr = @import("../common/power.zig");

pub const Reset = struct {
    power: *pwr.Power,
    last: u8 = 0,

    const port = 0xCF9;
    const sys_rst: u8 = 1 << 2;

    pub fn device(self: *Reset) io.PioDevice {
        return .{ .ptr = self, .base = port, .len = 1, .out_fn = onOut, .in_fn = onIn };
    }

    fn onOut(ptr: *anyopaque, p: u16, size: u8, value: u32) void {
        _ = p;
        _ = size;
        const self: *Reset = @ptrCast(@alignCast(ptr));
        self.last = @truncate(value);
        if (self.last & sys_rst != 0) self.power.request(.reset);
    }

    fn onIn(ptr: *anyopaque, p: u16, size: u8) u32 {
        _ = p;
        _ = size;
        const self: *Reset = @ptrCast(@alignCast(ptr));
        return self.last;
    }
};
