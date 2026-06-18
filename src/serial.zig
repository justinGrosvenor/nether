//! Minimal 16550 UART transmit path. Bytes written to the data port are
//! forwarded to `out_fd`. The line status register reports the transmitter
//! permanently ready so a polling guest driver makes progress. This is the
//! first member of the irreducible firmware floor; it grows toward a real 16550
//! (IER/FCR/LCR/MCR, RX path) when OVMF and Linux need it.

const std = @import("std");
const linux = std.os.linux;
const io = @import("io.zig");

pub const Serial = struct {
    out_fd: i32 = 1,

    const base = 0x3f8;
    const data_reg = base + 0;
    const lsr_reg = base + 5; // line status register

    pub fn device(self: *Serial) io.PioDevice {
        return .{
            .ptr = self,
            .base = base,
            .len = 8,
            .out_fn = onOut,
            .in_fn = onIn,
        };
    }

    fn onOut(ptr: *anyopaque, port: u16, size: u8, value: u32) void {
        _ = size;
        const self: *Serial = @ptrCast(@alignCast(ptr));
        if (port == data_reg) {
            const buf = [1]u8{@truncate(value)};
            _ = linux.write(self.out_fd, &buf, 1);
        }
    }

    fn onIn(ptr: *anyopaque, port: u16, size: u8) u32 {
        _ = ptr;
        _ = size;
        // LSR bit5 (THR empty) + bit6 (transmitter empty): always ready.
        if (port == lsr_reg) return 0x60;
        return 0;
    }
};
