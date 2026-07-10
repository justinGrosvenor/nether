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
const io = @import("../chipset/io.zig");
const Lock = @import("../common/lock.zig").Lock;

pub const Pl011 = struct {
    // Host -> guest receive ring (MPSC: a host thread pushes, the vCPU drains).
    rx_buf: [256]u8 = undefined,
    rx_head: usize = 0,
    rx_tail: usize = 0,
    mutex: Lock = .{},

    // Guest -> host transmit sink (stdout in the live VMM, a capture in tests).
    out_ctx: ?*anyopaque = null,
    out_fn: ?*const fn (ctx: *anyopaque, byte: u8) void = null,

    // Interrupt line to the GIC (level: asserted while a masked source is
    // pending). The host raises/lowers an SPI through this; null = no interrupts.
    imsc: u32 = 0, // interrupt mask (IMSC)
    irq_level: bool = false, // last level we reported
    irq_ctx: ?*anyopaque = null,
    irq_fn: ?*const fn (ctx: *anyopaque, level: bool) void = null,

    // Register offsets.
    const DR = 0x000; // data
    const FR = 0x018; // flag
    const IMSC = 0x038; // interrupt mask set/clear
    const RIS = 0x03C; // raw interrupt status
    const MIS = 0x040; // masked interrupt status
    const ICR = 0x044; // interrupt clear
    const PERIPH_ID0 = 0xFE0; // AMBA PrimeCell id (4 bytes) ...
    const PCELL_ID0 = 0xFF0; // ... then the PrimeCell id (4 bytes)

    // Flag register bits.
    const FR_RXFE = 1 << 4; // RX FIFO empty
    const FR_TXFF = 1 << 5; // TX FIFO full
    const FR_TXFE = 1 << 7; // TX FIFO empty

    // Interrupt bits (RX and receive-timeout share the RX-data condition here).
    const INT_RX = 1 << 4; // RXRIS / RXIM
    const INT_RT = 1 << 6; // RTRIS / RTIM

    // AMBA ids: peripheral 0x00041011, PrimeCell 0xB105F00D, one byte per word.
    const periph_id = [4]u8{ 0x11, 0x10, 0x14, 0x00 };
    const pcell_id = [4]u8{ 0x0D, 0xF0, 0x05, 0xB1 };

    pub fn device(self: *Pl011, base: u64) io.MmioDevice {
        return .{ .ptr = self, .base = base, .len = 0x1000, .read_fn = readThunk, .write_fn = writeThunk };
    }

    /// Snapshot of the guest-programmed register state (the RX ring is transient
    /// host input, not part of guest-visible architectural state). `imsc` is the
    /// load-bearing field: without it a restored UART has RX interrupts masked and
    /// the console goes deaf.
    pub const State = struct { imsc: u32, irq_level: bool };
    pub fn exportState(self: *const Pl011) State {
        return .{ .imsc = self.imsc, .irq_level = self.irq_level };
    }
    pub fn importState(self: *Pl011, s: State) void {
        self.imsc = s.imsc;
        self.irq_level = s.irq_level;
    }

    fn writeThunk(ptr: *anyopaque, offset: u64, data: []const u8) void {
        const self: *Pl011 = @ptrCast(@alignCast(ptr));
        switch (offset) {
            DR => if (data.len > 0) {
                if (self.out_fn) |f| f(self.out_ctx.?, data[0]);
            },
            IMSC => {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.imsc = leValue(data);
                self.refreshIrqLocked();
            },
            // ICR clears interrupts, but our RX source is level (follows the FIFO),
            // so it re-asserts until the guest drains DR; nothing to do. Other
            // control/baud registers are accepted and ignored.
            else => {},
        }
    }

    fn readThunk(ptr: *anyopaque, offset: u64, data: []u8) void {
        const self: *Pl011 = @ptrCast(@alignCast(ptr));
        const out: []u8 = data;
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
            IMSC => self.imsc,
            RIS => self.rawIrq(),
            MIS => self.rawIrq() & self.imsc,
            PERIPH_ID0, PERIPH_ID0 + 4, PERIPH_ID0 + 8, PERIPH_ID0 + 12 => periph_id[(offset - PERIPH_ID0) / 4],
            PCELL_ID0, PCELL_ID0 + 4, PCELL_ID0 + 8, PCELL_ID0 + 12 => pcell_id[(offset - PCELL_ID0) / 4],
            else => 0,
        };
    }

    /// Raw interrupt status: RX and receive-timeout asserted while RX has data.
    fn rawIrq(self: *Pl011) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.rx_head != self.rx_tail) (INT_RX | INT_RT) else 0;
    }

    /// Recompute the interrupt line and notify the GIC on a change. Lock held.
    fn refreshIrqLocked(self: *Pl011) void {
        const pending = self.rx_head != self.rx_tail and (self.imsc & (INT_RX | INT_RT)) != 0;
        if (pending != self.irq_level) {
            self.irq_level = pending;
            if (self.irq_fn) |f| f(self.irq_ctx.?, pending);
        }
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
        self.refreshIrqLocked(); // line drops once the FIFO drains
        return b;
    }

    /// Queue host input for the guest to read from DR, raising the RX interrupt.
    /// Safe to call from another thread (the RX ring is lock-guarded). Drops
    /// bytes when the ring is full.
    pub fn pushRx(self: *Pl011, bytes: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (bytes) |b| {
            if (self.rx_tail - self.rx_head >= self.rx_buf.len) break; // full
            self.rx_buf[self.rx_tail % self.rx_buf.len] = b;
            self.rx_tail += 1;
        }
        self.refreshIrqLocked();
    }
};

fn leValue(data: []const u8) u32 {
    var v: u32 = 0;
    for (data, 0..) |b, i| {
        if (i < 4) v |= @as(u32, b) << @intCast(i * 8);
    }
    return v;
}

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

test "RX interrupt asserts when masked-in and clears when the FIFO drains" {
    const Irq = struct {
        level: bool = false,
        edges: u32 = 0,
        fn set(ctx: *anyopaque, level: bool) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.level = level;
            self.edges += 1;
        }
    };
    var irq = Irq{};
    var uart = Pl011{ .irq_ctx = &irq, .irq_fn = Irq.set };
    const dev = uart.device(0x0900_0000);

    // Data arrives but RX interrupt not yet unmasked: line stays low.
    uart.pushRx("a");
    try std.testing.expect(!irq.level);

    // Driver unmasks RX (IMSC.RXIM): with data already pending, the line asserts.
    dev.write_fn(dev.ptr, 0x038, &[_]u8{ 0x10, 0, 0, 0 });
    try std.testing.expect(irq.level);
    // MIS reflects the masked RX source.
    var mis = [_]u8{ 0, 0, 0, 0 };
    dev.read_fn(dev.ptr, 0x040, &mis);
    try std.testing.expect(mis[0] & 0x10 != 0);

    // Guest drains DR -> FIFO empty -> line clears.
    var dr = [_]u8{0};
    dev.read_fn(dev.ptr, 0x000, &dr);
    try std.testing.expectEqual(@as(u8, 'a'), dr[0]);
    try std.testing.expect(!irq.level);
}
