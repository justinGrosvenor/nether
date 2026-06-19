//! 16550A UART at 0x3f8. Complete enough register file that the Linux 8250
//! driver's autoconfig accepts it and uses it as ttyS0: scratch readback, IER
//! readback, FIFO detection via IIR, the loopback MSR test, and LSR transmit-
//! ready. Transmitted bytes go to `out_fd`; in loopback mode they cycle back to
//! the receive register instead.

const std = @import("std");
const linux = std.os.linux;
const io = @import("io.zig");
const ioapic = @import("ioapic.zig");
const Lock = @import("lock.zig").Lock;
const Screen = @import("vt/Screen.zig");

pub const Serial = struct {
    out_fd: i32 = 1,
    irq: ?*ioapic.IoApic = null, // raised on TX-empty/RX-ready when enabled
    gsi: u8 = 4, // COM1 -> IRQ4
    /// Optional console tee: every transmitted byte is also fed to this screen,
    /// so the VMM keeps a live render of the guest console (for snapshots, a web
    /// console, or an on-exit dump). Touched only on the vCPU thread (the TX
    /// path), so it is single-writer and needs no lock; a future reader on
    /// another thread would (D3).
    mirror: ?*Screen = null,

    // The RX FIFO is filled by the host I/O thread (pushRx) and drained by the
    // vCPU thread (register reads), so all register state is under `mutex` (the
    // D3 per-device lock). The interrupt itself is raised outside the lock to
    // keep the serial->ioapic acquisition order one-directional.
    mutex: Lock = .{},
    rx_buf: [rx_cap]u8 = undefined,
    rx_head: usize = 0, // next slot to write
    rx_tail: usize = 0, // next slot to read

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
    const rx_cap = 64; // FIFO headroom for keystrokes between guest reads

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
    const ier_rdi = 0x01; // received-data interrupt enable
    const ier_thri = 0x02; // THR-empty interrupt enable

    pub fn device(self: *Serial) io.PioDevice {
        return .{ .ptr = self, .base = base, .len = span, .out_fn = onOut, .in_fn = onIn };
    }

    fn dlab(self: *Serial) bool {
        return self.lcr & lcr_dlab != 0;
    }

    fn onOut(ptr: *anyopaque, p: u16, size: u8, value: u32) void {
        _ = size;
        const self: *Serial = @ptrCast(@alignCast(ptr));
        const v: u8 = @truncate(value);
        self.mutex.lock();
        var raise = false;
        var emit: ?u8 = null; // byte to write to out_fd, after releasing the lock
        switch (p - base) {
            reg_data => if (self.dlab()) {
                self.dll = v;
            } else {
                if (self.mcr & mcr_loop != 0) {
                    self.loop_byte = v; // loopback: route back to RX
                    self.loop_full = true;
                } else {
                    emit = v;
                }
                if (self.ier & ier_thri != 0) raise = true; // THR empty again
            },
            reg_ier => if (self.dlab()) {
                self.dlm = v;
            } else {
                self.ier = v & 0x0f;
                if (self.ier & ier_thri != 0) raise = true; // THR is always empty
                if (self.ier & ier_rdi != 0 and !self.rxEmpty()) raise = true;
            },
            reg_iir_fcr => self.fifo_enabled = v & 0x01 != 0, // FCR
            reg_lcr => self.lcr = v,
            reg_mcr => self.mcr = v,
            reg_scr => self.scr = v,
            else => {}, // LSR and MSR are read-only
        }
        self.mutex.unlock();
        // The TX write and the IRQ raise are done outside the lock: the write can
        // block on a slow terminal, and the raise reaches into the IOAPIC (lock
        // order is serial -> ioapic, so it must not be held here).
        if (emit) |b| {
            const buf = [1]u8{b};
            if (self.out_fd >= 0) _ = linux.write(self.out_fd, &buf, 1); // -1 = headless
            if (self.mirror) |scr| scr.write(&buf); // tee into the console grid
        }
        if (raise) self.raiseIrq();
    }

    fn onIn(ptr: *anyopaque, p: u16, size: u8) u32 {
        _ = size;
        const self: *Serial = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        return switch (p - base) {
            reg_data => if (self.dlab()) self.dll else self.receive(),
            reg_ier => if (self.dlab()) self.dlm else self.ier,
            reg_iir_fcr => self.iir(),
            reg_lcr => self.lcr,
            reg_mcr => self.mcr,
            reg_lsr => self.lsr(),
            reg_msr => self.msr(),
            reg_scr => self.scr,
            else => 0,
        };
    }

    /// Host -> guest input. Called from the I/O thread: enqueue into the RX FIFO
    /// (dropping bytes only if the guest has fallen 64 keystrokes behind) and, if
    /// the guest has armed the received-data interrupt, raise IRQ4 so an idle
    /// shell wakes to drain it. The raise happens after the lock is released.
    pub fn pushRx(self: *Serial, bytes: []const u8) void {
        self.mutex.lock();
        for (bytes) |b| self.rxPush(b);
        const raise = self.ier & ier_rdi != 0 and !self.rxEmpty();
        self.mutex.unlock();
        if (raise) self.raiseIrq();
    }

    // RX ring helpers. All callers hold `mutex`. One slot is kept empty to
    // distinguish full from empty, so capacity is rx_cap-1 bytes.
    fn rxEmpty(self: *Serial) bool {
        return self.rx_head == self.rx_tail;
    }
    fn rxPush(self: *Serial, b: u8) void {
        const next = (self.rx_head + 1) % rx_cap;
        if (next == self.rx_tail) return; // full: drop the newest byte
        self.rx_buf[self.rx_head] = b;
        self.rx_head = next;
    }
    fn rxPop(self: *Serial) ?u8 {
        if (self.rxEmpty()) return null;
        const b = self.rx_buf[self.rx_tail];
        self.rx_tail = (self.rx_tail + 1) % rx_cap;
        return b;
    }

    fn receive(self: *Serial) u8 {
        if (self.loop_full) {
            self.loop_full = false;
            return self.loop_byte;
        }
        return self.rxPop() orelse 0;
    }

    fn raiseIrq(self: *Serial) void {
        if (self.irq) |ia| ia.raise(self.gsi);
    }

    /// Interrupt identification: highest-priority pending source. Reading it is
    /// how the guest's ISR learns whether to drain RX or refill TX.
    fn iir(self: *Serial) u32 {
        const fifo: u8 = if (self.fifo_enabled) 0xc0 else 0x00;
        if (!self.rxEmpty() and self.ier & ier_rdi != 0) return fifo | 0x04; // RX data
        if (self.ier & ier_thri != 0) return fifo | 0x02; // THR empty
        return fifo | 0x01; // none pending
    }

    fn lsr(self: *Serial) u8 {
        // THRE (0x20) + TEMT (0x40) always; DR (0x01) when a byte is waiting.
        const dr: u8 = if (self.loop_full or !self.rxEmpty()) 0x01 else 0x00;
        return 0x60 | dr;
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

test "pushRx delivers bytes in order and sets LSR data-ready" {
    var s = Serial{};
    const d = s.device();
    try std.testing.expectEqual(@as(u8, 0x60), in(d, 5)); // no data yet
    s.pushRx("hi");
    try std.testing.expect(in(d, 5) & 0x01 != 0); // DR set
    try std.testing.expectEqual(@as(u8, 'h'), in(d, 0));
    try std.testing.expectEqual(@as(u8, 'i'), in(d, 0));
    try std.testing.expectEqual(@as(u8, 0x60), in(d, 5)); // drained
    try std.testing.expectEqual(@as(u8, 0x00), in(d, 0)); // empty reads 0
}

test "IIR reports RX-data only when RDI armed" {
    var s = Serial{};
    const d = s.device();
    s.pushRx("x");
    try std.testing.expectEqual(@as(u8, 0x01), in(d, 2)); // RDI off: none pending
    out(d, 1, Serial.ier_rdi); // arm received-data interrupt
    try std.testing.expectEqual(@as(u8, 0x04), in(d, 2)); // now RX-data pending
}

test "RX FIFO drops newest when full, keeps the backlog readable" {
    var s = Serial{};
    const d = s.device();
    var sent: [Serial.rx_cap + 16]u8 = undefined;
    for (&sent, 0..) |*b, i| b.* = @truncate(i);
    s.pushRx(&sent);
    // Capacity is rx_cap-1; the first that-many bytes survive, the rest dropped.
    var i: usize = 0;
    while (i < Serial.rx_cap - 1) : (i += 1) {
        try std.testing.expectEqual(@as(u8, @truncate(i)), in(d, 0));
    }
    try std.testing.expectEqual(@as(u8, 0x60), in(d, 5)); // nothing left
}

test "concurrent producer/consumer preserves FIFO order with no duplication" {
    // The point of the per-device lock: pushRx (host I/O thread) and register
    // reads (vCPU thread) touch the RX ring from two threads. Drive both at once
    // and assert the consumer sees a strictly increasing subsequence of what was
    // pushed: in order, never duplicated, never reordered. Drops are allowed (the
    // ring is finite) but show up only as gaps, never as disorder.
    const count = 200; // < 256 so byte values do not wrap
    var s = Serial{};
    const d = s.device();

    const Producer = struct {
        fn run(serial: *Serial) void {
            var i: u8 = 0;
            while (i < count) : (i += 1) serial.pushRx(&[_]u8{i});
        }
    };
    var t = try std.Thread.spawn(.{}, Producer.run, .{&s});

    var last: i32 = -1;
    var received: usize = 0;
    var idle: usize = 0;
    while (idle < 100000) {
        if (in(d, 5) & 0x01 != 0) { // LSR data-ready
            const b = in(d, 0);
            try std.testing.expect(@as(i32, b) > last); // strictly increasing
            last = b;
            received += 1;
            idle = 0;
        } else {
            idle += 1;
        }
    }
    t.join();
    // Drain anything still queued after the producer finished.
    while (in(d, 5) & 0x01 != 0) {
        const b = in(d, 0);
        try std.testing.expect(@as(i32, b) > last);
        last = b;
        received += 1;
    }
    try std.testing.expect(received >= 1); // made progress
    try std.testing.expect(received <= count); // no duplication
}

test "console tee mirrors transmitted bytes into a screen" {
    var screen = try Screen.init(std.testing.allocator, 4, 20);
    defer screen.deinit();
    // out_fd = -1 so the physical write is a harmless no-op in the test; the tee
    // still captures every byte.
    var s = Serial{ .out_fd = -1, .mirror = &screen };
    const d = s.device();
    for ("hi\r\nthere") |c| out(d, 0, c);
    var buf: [80]u8 = undefined;
    try std.testing.expectEqualStrings("hi", std.mem.trimEnd(u8, screen.rowText(0, &buf), " "));
    try std.testing.expectEqualStrings("there", std.mem.trimEnd(u8, screen.rowText(1, &buf), " "));
}

test "loopback routes transmit to receive" {
    var s = Serial{};
    const d = s.device();
    out(d, 4, 0x10); // loopback on
    out(d, 0, 0x77); // transmit
    try std.testing.expect(in(d, 5) & 0x01 != 0); // LSR data-ready
    try std.testing.expectEqual(@as(u8, 0x77), in(d, 0)); // read it back
}
