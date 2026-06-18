//! 16550A UART at 0x3f8. Complete enough register file that the Linux 8250
//! driver's autoconfig accepts it and uses it as ttyS0: scratch readback, IER
//! readback, FIFO detection via IIR, the loopback MSR test, and LSR transmit-
//! ready. Transmitted bytes go to `out_fd`; in loopback mode they cycle back to
//! the receive register instead.

const std = @import("std");
const linux = std.os.linux;
const io = @import("io.zig");

pub const Serial = struct {
    out_fd: i32 = 1,

    ier: u8 = 0,
    lcr: u8 = 0,
    mcr: u8 = 0,
    scr: u8 = 0,
    dll: u8 = 0,
    dlm: u8 = 0,
    fifo_enabled: bool = false,
    loop_byte: u8 = 0,
    loop_full: bool = false,

    const base = 0x3f8;
    const span = 8;

    // Register offsets from base.
    const reg_data = 0; // THR/RBR, or DLL when DLAB=1
    const reg_ier = 1; // IER, or DLM when DLAB=1
    const reg_iir_fcr = 2; // IIR (read) / FCR (write)
    const reg_lcr = 3; // LCR (bit 7 = DLAB)
    const reg_mcr = 4; // MCR (bit 4 = loopback)
    const reg_lsr = 5; // LSR (read-only)
    const reg_msr = 6; // MSR (read-only)
    const reg_scr = 7; // scratch

    const lcr_dlab = 0x80;
    const mcr_loop = 0x10;

    pub fn device(self: *Serial) io.PioDevice {
        return .{ .ptr = self, .base = base, .len = span, .out_fn = onOut, .in_fn = onIn };
    }

    fn dlab(self: *Serial) bool {
        return self.lcr & lcr_dlab != 0;
    }

    fn transmit(self: *Serial, byte: u8) void {
        if (self.mcr & mcr_loop != 0) {
            self.loop_byte = byte; // loopback: route back to RX
            self.loop_full = true;
        } else {
            const buf = [1]u8{byte};
            _ = linux.write(self.out_fd, &buf, 1);
        }
    }

    fn onOut(ptr: *anyopaque, p: u16, size: u8, value: u32) void {
        _ = size;
        const self: *Serial = @ptrCast(@alignCast(ptr));
        const v: u8 = @truncate(value);
        switch (p - base) {
            reg_data => if (self.dlab()) {
                self.dll = v;
            } else {
                self.transmit(v);
            },
            reg_ier => if (self.dlab()) {
                self.dlm = v;
            } else {
                self.ier = v & 0x0f;
            },
            reg_iir_fcr => self.fifo_enabled = v & 0x01 != 0, // FCR
            reg_lcr => self.lcr = v,
            reg_mcr => self.mcr = v,
            reg_scr => self.scr = v,
            else => {}, // LSR and MSR are read-only
        }
    }

    fn onIn(ptr: *anyopaque, p: u16, size: u8) u32 {
        _ = size;
        const self: *Serial = @ptrCast(@alignCast(ptr));
        return switch (p - base) {
            reg_data => if (self.dlab()) self.dll else self.receive(),
            reg_ier => if (self.dlab()) self.dlm else self.ier,
            reg_iir_fcr => if (self.fifo_enabled) 0xc1 else 0x01, // no int pending; FIFO bits
            reg_lcr => self.lcr,
            reg_mcr => self.mcr,
            reg_lsr => self.lsr(),
            reg_msr => self.msr(),
            reg_scr => self.scr,
            else => 0,
        };
    }

    fn receive(self: *Serial) u8 {
        if (self.loop_full) {
            self.loop_full = false;
            return self.loop_byte;
        }
        return 0;
    }

    fn lsr(self: *Serial) u8 {
        // THRE (0x20) + TEMT (0x40) always; DR (0x01) if loopback data waiting.
        return 0x60 | @as(u8, if (self.loop_full) 0x01 else 0x00);
    }

    fn msr(self: *Serial) u8 {
        if (self.mcr & mcr_loop != 0) {
            // Loopback maps MCR control bits to MSR status bits.
            var v: u8 = 0;
            if (self.mcr & 0x01 != 0) v |= 0x20; // DTR -> DSR
            if (self.mcr & 0x02 != 0) v |= 0x10; // RTS -> CTS
            if (self.mcr & 0x04 != 0) v |= 0x40; // OUT1 -> RI
            if (self.mcr & 0x08 != 0) v |= 0x80; // OUT2 -> DCD
            return v;
        }
        return 0xb0; // DCD | DSR | CTS: carrier present
    }
};

fn out(dev: io.PioDevice, off: u16, v: u8) void {
    dev.out_fn(dev.ptr, 0x3f8 + off, 1, v);
}
fn in(dev: io.PioDevice, off: u16) u8 {
    return @intCast(dev.in_fn(dev.ptr, 0x3f8 + off, 1));
}

test "scratch register reads back" {
    var s = Serial{};
    const d = s.device();
    out(d, 7, 0xa5);
    try std.testing.expectEqual(@as(u8, 0xa5), in(d, 7));
    out(d, 7, 0x5a);
    try std.testing.expectEqual(@as(u8, 0x5a), in(d, 7));
}

test "IER low nibble reads back" {
    var s = Serial{};
    const d = s.device();
    out(d, 1, 0x0f);
    try std.testing.expectEqual(@as(u8, 0x0f), in(d, 1));
}

test "IIR reports 16550A FIFO after enable" {
    var s = Serial{};
    const d = s.device();
    try std.testing.expectEqual(@as(u8, 0x01), in(d, 2)); // no FIFO yet
    out(d, 2, 0x01); // FCR: enable FIFO
    try std.testing.expectEqual(@as(u8, 0xc1), in(d, 2));
}

test "loopback MSR test passes the 8250 sanity check" {
    var s = Serial{};
    const d = s.device();
    out(d, 4, mcrLoop()); // MCR = LOOP | OUT2 | RTS
    try std.testing.expectEqual(@as(u8, 0x90), in(d, 6) & 0xf0); // expect DCD | CTS
}

fn mcrLoop() u8 {
    return 0x10 | 0x08 | 0x02;
}

test "DLAB switches data/IER to divisor latches" {
    var s = Serial{};
    const d = s.device();
    out(d, 3, 0x80); // LCR: DLAB = 1
    out(d, 0, 0x34); // DLL
    out(d, 1, 0x12); // DLM
    try std.testing.expectEqual(@as(u8, 0x34), in(d, 0));
    try std.testing.expectEqual(@as(u8, 0x12), in(d, 1));
    out(d, 3, 0x00); // DLAB = 0
    try std.testing.expectEqual(@as(u8, 0x60), in(d, 5)); // LSR transmit-ready
}

test "loopback routes transmit to receive" {
    var s = Serial{};
    const d = s.device();
    out(d, 4, 0x10); // loopback on
    out(d, 0, 0x77); // transmit
    try std.testing.expect(in(d, 5) & 0x01 != 0); // LSR data-ready
    try std.testing.expectEqual(@as(u8, 0x77), in(d, 0)); // read it back
}
