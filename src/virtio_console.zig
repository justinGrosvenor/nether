//! virtio-console backend (virtio 1.x, device id 3). A serial/console device
//! exposed over the same `virtio.Device` transport + `virtq` datapath as the
//! other backends. Chosen as the first end-to-end datapath proof on aarch64/HVF
//! because `virtio_console` is one of the only virtio leaf drivers built into the
//! stock Alpine `virt` kernel (the rest are modules absent from the minirootfs),
//! so it actually binds and creates `/dev/hvc0`.
//!
//! Single port, no multiport: two virtqueues
//!   * RXQ=0 (host -> guest): the guest posts writable buffers; when host input
//!     arrives we place it into an available chain and raise the completion. Same
//!     two-thread shape as virtio-net RX; the device `Lock` serializes the rings.
//!   * TXQ=1 (guest -> host, vCPU thread): on a kick we gather each chain's
//!     readable bytes and hand them to the host sink (stdout in the live VMM).
//!
//! We negotiate no console features (no SIZE, no MULTIPORT, no EMERG_WRITE), so
//! port 0 is usable immediately and the device-config fields are never consulted.

const std = @import("std");
const virtio = @import("virtio.zig");
const virtq = @import("virtq.zig");
const Lock = @import("lock.zig").Lock;
const trace = @import("trace.zig");

pub const VIRTIO_ID_CONSOLE = 3;
pub const RXQ: u16 = 0; // host -> guest (device-initiated)
pub const TXQ: u16 = 1; // guest -> host

/// Largest single TX chunk we gather before flushing to the sink.
pub const TX_CHUNK = 4096;

pub const Console = struct {
    dev: *virtio.Device = undefined,
    attached: bool = false,
    lock: Lock = .{},

    /// Host sink for guest-transmitted bytes (stdout in the live VMM).
    out_fn: ?*const fn (ctx: *anyopaque, bytes: []const u8) void = null,
    out_ctx: ?*anyopaque = null,

    tx_scratch: [TX_CHUNK]u8 = undefined,

    pub fn backend(self: *Console) virtio.Backend {
        return .{
            .ptr = self,
            .device_id = VIRTIO_ID_CONSOLE,
            .num_queues = 2,
            .device_features = 0, // no SIZE/MULTIPORT/EMERG_WRITE
            .notify = onNotify,
            .config_read = configRead,
        };
    }

    /// Bind the transport so the input thread can push bytes between kicks.
    pub fn attach(self: *Console, dev: *virtio.Device) void {
        self.dev = dev;
        self.attached = true;
    }

    /// virtio_console_config (cols, rows, max_nr_ports, emerg_wr) - never read
    /// since we negotiate none of the gating features.
    fn configRead(ptr: *anyopaque, off: u16, size: u8) u32 {
        _ = ptr;
        _ = off;
        _ = size;
        return 0;
    }

    fn onNotify(ptr: *anyopaque, dev: *virtio.Device, q: u16) void {
        const self = cast(ptr);
        self.dev = dev;
        self.attached = true;
        switch (q) {
            TXQ => self.handleTx(dev),
            // RXQ kick = the guest posted input buffers. Nothing to do until host
            // input arrives; pushRx consumes them then.
            else => {},
        }
    }

    /// vCPU thread: drain the TX ring. The ring walk runs under the lock; the
    /// sink delivery (a host write syscall) happens after unlocking, so no slow
    /// syscall is held under the device lock (D3).
    fn handleTx(self: *Console, dev: *virtio.Device) void {
        const mem = dev.memory();
        const vq = dev.queue(TXQ);
        var consumed = false;
        while (true) {
            self.lock.lock();
            const head = vq.next(mem) orelse {
                self.lock.unlock();
                break;
            };
            const n = self.gather(mem, vq, head);
            vq.complete(mem, head, 0); // TX buffers are device-read-only
            self.lock.unlock();
            consumed = true;
            if (n > 0) {
                trace.log("console tx bytes={d}", .{n});
                if (self.out_fn) |f| f(self.out_ctx.?, self.tx_scratch[0..n]);
            }
        }
        if (consumed) dev.interruptQueue(TXQ);
    }

    /// Host thread: deliver input bytes to the guest by filling one available RX
    /// chain. Returns the number of bytes placed (0 if no buffer is posted, so
    /// the caller can retry or drop). Bytes beyond the chain's capacity are not
    /// consumed here; call again once the guest posts more buffers.
    pub fn pushRx(self: *Console, bytes: []const u8) usize {
        if (!self.attached or bytes.len == 0) return 0;
        const dev = self.dev;
        const mem = dev.memory();
        const vq = dev.queue(RXQ);

        self.lock.lock();
        if (!vq.hasNext(mem)) {
            self.lock.unlock();
            trace.log("console rx drop (no buffer) bytes={d}", .{bytes.len});
            return 0;
        }
        const head = vq.next(mem).?;
        const written = scatter(mem, vq, head, bytes);
        vq.complete(mem, head, written);
        self.lock.unlock();

        trace.log("console rx delivered={d}", .{written});
        dev.interruptQueue(RXQ); // after unlock, per D3
        return written;
    }

    /// Gather a TX chain's device-readable bytes into tx_scratch (capped).
    fn gather(self: *Console, mem: virtq.GuestMem, vq: *virtq.Virtqueue, head: u16) usize {
        var n: usize = 0;
        var it = vq.chain(mem, head);
        while (it.next()) |b| {
            if (b.writable) continue;
            const src = mem.slice(b.addr, b.len) orelse continue;
            const take = @min(self.tx_scratch.len - n, src.len);
            @memcpy(self.tx_scratch[n..][0..take], src[0..take]);
            n += take;
            if (n == self.tx_scratch.len) break;
        }
        return n;
    }

    /// Copy input across an RX chain's device-writable buffers.
    fn scatter(mem: virtq.GuestMem, vq: *virtq.Virtqueue, head: u16, src: []const u8) u32 {
        var off: usize = 0;
        var it = vq.chain(mem, head);
        while (it.next()) |b| {
            if (!b.writable) continue;
            if (off == src.len) break;
            const dst = mem.slice(b.addr, b.len) orelse continue;
            const take = @min(dst.len, src.len - off);
            @memcpy(dst[0..take], src[off..][0..take]);
            off += take;
        }
        return @intCast(off);
    }
};

fn cast(ptr: *anyopaque) *Console {
    return @ptrCast(@alignCast(ptr));
}

// --- tests -----------------------------------------------------------------
//
// Memory layout in the shared `ram` (guest base 0):
//   TX queue: desc 0x0000, avail 0x0200, used 0x0400
//   RX queue: desc 0x0600, avail 0x0800, used 0x0A00
//   TX data 0x1000; RX buffer 0x2000

const testing = std.testing;

const TX_DESC = 0x0000;
const TX_AVAIL = 0x0200;
const TX_USED = 0x0400;
const RX_DESC = 0x0600;
const RX_AVAIL = 0x0800;
const RX_USED = 0x0A00;

fn progQueue(dev: *virtio.Device, sel: u16, size: u16, desc: u32, avail: u32, used: u32) void {
    dev.barWrite(0x16, 2, sel);
    dev.barWrite(0x18, 2, size);
    dev.barWrite(0x20, 4, desc);
    dev.barWrite(0x28, 4, avail);
    dev.barWrite(0x30, 4, used);
    dev.barWrite(0x1c, 2, 1); // enable
}

fn wdesc(ram: []u8, at: usize, gpa: u64, len: u32, flags: u16, next: u16) void {
    std.mem.writeInt(u64, ram[at..][0..8], gpa, .little);
    std.mem.writeInt(u32, ram[at + 8 ..][0..4], len, .little);
    std.mem.writeInt(u16, ram[at + 12 ..][0..2], flags, .little);
    std.mem.writeInt(u16, ram[at + 14 ..][0..2], next, .little);
}

const Sink = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    fn write(ctx: *anyopaque, bytes: []const u8) void {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
};

test "console TX gathers guest bytes and delivers them to the host sink" {
    var ram = [_]u8{0} ** 8192;
    var con = Console{};
    var dev = virtio.Device.init(con.backend(), .{ .bytes = &ram, .base = 0 });
    var sink = Sink{};
    con.out_fn = Sink.write;
    con.out_ctx = &sink;

    progQueue(&dev, TXQ, 8, TX_DESC, TX_AVAIL, TX_USED);

    const msg = "hello hvc0\n";
    @memcpy(ram[0x1000..][0..msg.len], msg);
    wdesc(&ram, TX_DESC, 0x1000, msg.len, 0, 0); // one readable buffer
    std.mem.writeInt(u16, ram[TX_AVAIL + 2 ..][0..2], 1, .little); // avail.idx
    std.mem.writeInt(u16, ram[TX_AVAIL + 4 ..][0..2], 0, .little); // ring[0]=desc0

    dev.barWrite(0x2000, 4, TXQ); // notify TXQ

    try testing.expectEqualStrings(msg, sink.buf[0..sink.len]);
    // Used ring advanced and the completion interrupt fired.
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ram[TX_USED + 2 ..][0..2], .little));
    try testing.expect(dev.isr & 1 != 0);
}

test "console RX places host input into a guest buffer and interrupts" {
    var ram = [_]u8{0} ** 16384;
    var con = Console{};
    var dev = virtio.Device.init(con.backend(), .{ .bytes = &ram, .base = 0 });
    con.attach(&dev);

    progQueue(&dev, RXQ, 8, RX_DESC, RX_AVAIL, RX_USED);

    // One writable 32-byte buffer at 0x2000.
    wdesc(&ram, RX_DESC, 0x2000, 32, virtq.DESC_F_WRITE, 0);
    std.mem.writeInt(u16, ram[RX_AVAIL + 2 ..][0..2], 1, .little); // avail.idx
    std.mem.writeInt(u16, ram[RX_AVAIL + 4 ..][0..2], 0, .little); // ring[0]=desc0

    const input = "abc";
    const n = con.pushRx(input);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings(input, ram[0x2000..][0..3]);
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, ram[RX_USED + 8 ..][0..4], .little)); // used[0].len
    try testing.expect(dev.isr & 1 != 0);
}

test "console RX with no posted buffer drops without crashing" {
    var ram = [_]u8{0} ** 4096;
    var con = Console{};
    var dev = virtio.Device.init(con.backend(), .{ .bytes = &ram, .base = 0 });
    con.attach(&dev);
    progQueue(&dev, RXQ, 8, RX_DESC, RX_AVAIL, RX_USED);
    // No avail buffers posted (avail.idx stays 0).
    try testing.expectEqual(@as(usize, 0), con.pushRx("x"));
}
