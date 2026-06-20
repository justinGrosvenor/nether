//! ARM PrimeCell PL011 UART, the standard console on the arm64 "virt" platform
//! (the aarch64 analog of the 16550 in serial.zig). Output goes to a host sink;
//! input is queued in an RX ring fed by a host I/O thread. Interrupt delivery
//! (RX/TX via the GIC) lands with the GIC chunk; for now the guest polls the
//! flag register, which is what early console paths do.
//!
//! Registers are at the offsets Linux's amba-pl011 driver expects, including the
//! AMBA PrimeCell ID registers at 0xFE0-0xFFC so the driver's bus match (peripid
//! 0x00041011) succeeds when the device is described in the DTB.

const std = @import("std");
const io = @import("io.zig");
const Lock = @import("lock.zig").Lock;

pub const Pl011 = struct {
    // Host -> guest receive ring (MPSC: a host thread pushes, the vCPU drains).
    rx_buf: [256]u8 = undefined,
    rx_head: usize = 0,
    rx_tail: usize = 0,
    mutex: Lock = .{},

    // Guest -> host transmit sink (stdout in the live VMM, a capture in tests).
    out_ctx: ?*anyopaque = null,
    out_fn: ?*const fn (ctx: *anyopaque, byte: u8) void = null,

    // Register offsets.
    const DR = 0x000; // data
    const FR = 0x018; // flag
    const PERIPH_ID0 = 0xFE0; // AMBA PrimeCell id (4 bytes) ...
    const PCELL_ID0 = 0xFF0; // ... then the PrimeCell id (4 bytes)

    // Flag register bits.
    const FR_RXFE = 1 << 4; // RX FIFO empty
    const FR_TXFF = 1 << 5; // TX FIFO full
    const FR_TXFE = 1 << 7; // TX FIFO empty

    // AMBA ids: peripheral 0x00041011, PrimeCell 0xB105F00D, one byte per word.
    const periph_id = [4]u8{ 0x11, 0x10, 0x14, 0x00 };
    const pcell_id = [4]u8{ 0x0D, 0xF0, 0x05, 0xB1 };

    pub fn device(self: *Pl011, base: u64) io.MmioDevice {
        return .{ .ptr = self, .base = base, .len = 0x1000, .read_fn = readThunk, .write_fn = writeThunk };
    }

    fn writeThunk(ptr: *anyopaque, offset: u64, data: []const u8) void {
        const self: *Pl011 = @ptrCast(@alignCast(ptr));
        if (offset == DR and data.len > 0) {
            if (self.out_fn) |f| f(self.out_ctx.?, data[0]);
        }
        // Control/baud/interrupt-mask registers are accepted and ignored; we run
        // no real line discipline and (yet) no interrupts.
    }

    fn readThunk(ptr: *anyopaque, offset: u64, data: []const u8) void {
        const self: *Pl011 = @ptrCast(@alignCast(ptr));
        const out: []u8 = @constCast(data);
        @memset(out, 0);
        const v: u32 = self.reg(offset);
        for (out, 0..) |*b, i| {
            if (i < 4) b.* = @truncate(v >> @intCast(i * 8));
        }
    }

    fn reg(self: *Pl011, offset: u64) u32 {
        return switch (offset) {
            DR => self.popRx(),
            FR => self.flags(),
            PERIPH_ID0, PERIPH_ID0 + 4, PERIPH_ID0 + 8, PERIPH_ID0 + 12 => periph_id[(offset - PERIPH_ID0) / 4],
            PCELL_ID0, PCELL_ID0 + 4, PCELL_ID0 + 8, PCELL_ID0 + 12 => pcell_id[(offset - PCELL_ID0) / 4],
            else => 0,
        };
    }

    fn flags(self: *Pl011) u32 {
        self.mutex.lock();
        const empty = self.rx_head == self.rx_tail;
        self.mutex.unlock();
        // TX is always ready (empty, never full); RXFE set when the ring is empty.
        return FR_TXFE | (if (empty) @as(u32, FR_RXFE) else 0);
    }

    fn popRx(self: *Pl011) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.rx_head == self.rx_tail) return 0;
        const b = self.rx_buf[self.rx_head % self.rx_buf.len];
        self.rx_head += 1;
        return b;
    }

    /// Queue host input for the guest to read from DR. Safe to call from another
    /// thread (the RX ring is lock-guarded). Drops bytes when the ring is full.
    pub fn pushRx(self: *Pl011, bytes: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (bytes) |b| {
            if (self.rx_tail - self.rx_head >= self.rx_buf.len) break; // full
            self.rx_buf[self.rx_tail % self.rx_buf.len] = b;
            self.rx_tail += 1;
        }
    }
};

// --- tests -----------------------------------------------------------------

const Sink = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    fn take(ctx: *anyopaque, byte: u8) void {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        if (self.len < self.buf.len) self.buf[self.len] = byte;
        self.len += 1;
    }
};

test "DR writes reach the host sink" {
    var sink = Sink{};
    var uart = Pl011{ .out_ctx = &sink, .out_fn = Sink.take };
    const dev = uart.device(0x0900_0000);
    dev.write_fn(dev.ptr, 0x000, "Hi");
    dev.write_fn(dev.ptr, 0x000, &[_]u8{'!'}); // one byte per DR write
    // The driver writes one byte per access; only the first of a multi-byte
    // store is the data byte, but our test feeds single bytes.
    try std.testing.expectEqual(@as(usize, 2), sink.len);
    try std.testing.expectEqual(@as(u8, 'H'), sink.buf[0]);
    try std.testing.expectEqual(@as(u8, '!'), sink.buf[1]);
}

test "FR reports TX ready and RX empty, then not-empty after pushRx" {
    var uart = Pl011{};
    const dev = uart.device(0x0900_0000);
    var fr = [_]u8{ 0, 0, 0, 0 };
    dev.read_fn(dev.ptr, 0x018, &fr);
    try std.testing.expectEqual(@as(u8, 0x80 | 0x10), fr[0]); // TXFE | RXFE

    uart.pushRx("x");
    dev.read_fn(dev.ptr, 0x018, &fr);
    try std.testing.expectEqual(@as(u8, 0x80), fr[0]); // TXFE, RX no longer empty

    var dr = [_]u8{0};
    dev.read_fn(dev.ptr, 0x000, &dr);
    try std.testing.expectEqual(@as(u8, 'x'), dr[0]);
    // Drained: RXFE set again.
    dev.read_fn(dev.ptr, 0x018, &fr);
    try std.testing.expectEqual(@as(u8, 0x90), fr[0]);
}

test "AMBA PrimeCell ids match the pl011 driver's expected peripheral id" {
    var uart = Pl011{};
    const dev = uart.device(0x0900_0000);
    var pid: u32 = 0;
    var off: u64 = 0xFE0;
    var i: u5 = 0;
    while (i < 4) : (i += 1) {
        var b = [_]u8{ 0, 0, 0, 0 };
        dev.read_fn(dev.ptr, off, &b);
        pid |= @as(u32, b[0]) << @intCast(i * 8);
        off += 4;
    }
    // Linux matches amba_id 0x00041011 under mask 0x000fffff (revision masked).
    try std.testing.expectEqual(@as(u32, 0x00041011), pid & 0x000fffff);
}
