//! virtio-net backend: the NIC that completes the Phase 3 device set.
//!
//! Two datapaths over two virtqueues (RX=0, TX=1), each frame prefixed by a
//! 12-byte virtio_net_hdr (v1; we run no offloads, so the header is zeroed with
//! num_buffers=1 on RX and ignored on TX):
//!
//!   * TX (guest -> host, vCPU thread): on a queue-1 kick, gather each chain's
//!     readable bytes, strip the 12-byte header, and hand the raw Ethernet frame
//!     to the host sink (`on_tx`, which writes a tap fd in the live VMM). The tap
//!     write is a syscall, so it happens after releasing the device lock (D3).
//!
//!   * RX (host -> guest, device-initiated): the host reads a frame off the tap
//!     on its own thread and calls `pushRx`, which prepends the header and places
//!     the packet into an available RX chain, then raises the completion. Same
//!     two-thread shape as vsock RX; the device `Lock` serializes the rings.
//!
//! Like a real NIC, RX frames are dropped when the guest has posted no buffer or
//! the frame is oversized. We advertise VIRTIO_NET_F_MAC (a stable MAC) and no
//! offload/mergeable-buffer features, so the guest sends and receives plain
//! frames. The tap plumbing itself is Linux-only and lives in main.zig.

const std = @import("std");
const virtio = @import("virtio.zig");
const virtq = @import("virtq.zig");
const Lock = @import("../common/lock.zig").Lock;
const trace = @import("../common/trace.zig");

pub const VIRTIO_ID_NET = 1;
pub const RXQ: u16 = 0; // host -> guest (device-initiated)
pub const TXQ: u16 = 1; // guest -> host

/// virtio_net_hdr_v1: flags, gso_type, hdr_len, gso_size, csum_start,
/// csum_offset, num_buffers. With VIRTIO_F_VERSION_1 the header is always 12
/// bytes and num_buffers (at offset 10) is present.
const NET_HDR_LEN = 12;
const NUM_BUFFERS_OFF = 10;

/// Max Ethernet frame we move (default 1500 MTU + headers, with headroom). We
/// negotiate no GSO/TSO, so the guest never sends anything larger.
pub const FRAME_MAX = 2048;

const VIRTIO_NET_F_MAC: u64 = 1 << 5;

pub const Net = struct {
    dev: *virtio.Device = undefined,
    attached: bool = false,
    lock: Lock = .{},
    /// Locally-administered MAC (52:54:00 is the QEMU/KVM OUI).
    mac: [6]u8 = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 },

    /// Host sink for guest-transmitted frames (the tap write in the live VMM).
    on_tx: ?*const fn (ctx: *anyopaque, frame: []const u8) void = null,
    on_tx_ctx: ?*anyopaque = null,

    tx_scratch: [NET_HDR_LEN + FRAME_MAX]u8 = undefined, // gather a TX chain
    rx_scratch: [NET_HDR_LEN + FRAME_MAX]u8 = undefined, // build an RX packet

    pub fn backend(self: *Net) virtio.Backend {
        return .{
            .ptr = self,
            .device_id = VIRTIO_ID_NET,
            .num_queues = 2,
            .device_features = VIRTIO_NET_F_MAC,
            .notify = onNotify,
            .config_read = configRead,
        };
    }

    /// Bind the transport so the tap-reader thread can push frames between kicks.
    pub fn attach(self: *Net, dev: *virtio.Device) void {
        self.dev = dev;
        self.attached = true;
    }

    /// virtio_net_config: mac[6] at offset 0, then status (u16, unused here).
    fn configRead(ptr: *anyopaque, off: u16, size: u8) u32 {
        const self = cast(ptr);
        var bytes = [_]u8{0} ** 8; // mac[6] + status(2), status left 0
        @memcpy(bytes[0..6], &self.mac);
        var v: u32 = 0;
        var i: u8 = 0;
        // `i < 4`: the result is a u32, and an oversized guest config access (size > 4)
        // would otherwise drive the `i*8` shift past the u5 width and panic.
        while (i < size and i < 4 and off + i < bytes.len) : (i += 1) {
            v |= @as(u32, bytes[off + i]) << @intCast(i * 8);
        }
        return v;
    }

    fn onNotify(ptr: *anyopaque, dev: *virtio.Device, q: u16) void {
        const self = cast(ptr);
        self.dev = dev;
        self.attached = true;
        switch (q) {
            TXQ => self.handleTx(dev),
            // RXQ kick = the guest posted RX buffers. Nothing to do until a frame
            // arrives from the host; pushRx consumes them then.
            else => {},
        }
    }

    /// vCPU thread: drain the TX ring one frame at a time. The ring walk runs
    /// under the lock; the on_tx delivery (a tap-fd write) runs after unlocking,
    /// so no slow syscall is held under the device lock.
    fn handleTx(self: *Net, dev: *virtio.Device) void {
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
            if (n > NET_HDR_LEN) {
                const frame = self.tx_scratch[NET_HDR_LEN..n];
                trace.log("net tx frame={d}", .{frame.len});
                if (self.on_tx) |f| f(self.on_tx_ctx.?, frame);
            }
        }
        if (consumed) dev.interruptQueue(TXQ);
    }

    /// Host thread: place one received frame into an available RX chain. Returns
    /// false if the frame was dropped (oversized, not attached, or no buffer).
    pub fn pushRx(self: *Net, frame: []const u8) bool {
        if (!self.attached or frame.len > FRAME_MAX) return false;
        const dev = self.dev;
        const mem = dev.memory();
        const vq = dev.queue(RXQ);

        self.lock.lock();
        if (!vq.hasNext(mem)) {
            self.lock.unlock();
            trace.log("net rx drop (no buffer) frame={d}", .{frame.len});
            return false;
        }
        const head = vq.next(mem).?;
        @memset(self.rx_scratch[0..NET_HDR_LEN], 0);
        std.mem.writeInt(u16, self.rx_scratch[NUM_BUFFERS_OFF..][0..2], 1, .little);
        @memcpy(self.rx_scratch[NET_HDR_LEN..][0..frame.len], frame);
        const total = NET_HDR_LEN + frame.len;
        const written = scatter(mem, vq, head, self.rx_scratch[0..total]);
        vq.complete(mem, head, written);
        self.lock.unlock();

        trace.log("net rx frame={d} written={d}", .{ frame.len, written });
        dev.interruptQueue(RXQ); // after unlock, per D3
        return true;
    }

    /// Gather a TX chain's device-readable bytes into tx_scratch (capped).
    fn gather(self: *Net, mem: virtq.GuestMem, vq: *virtq.Virtqueue, head: u16) usize {
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

    /// Copy a packet across an RX chain's device-writable buffers.
    fn scatter(mem: virtq.GuestMem, vq: *virtq.Virtqueue, head: u16, pkt: []const u8) u32 {
        var off: usize = 0;
        var it = vq.chain(mem, head);
        while (it.next()) |b| {
            if (!b.writable) continue;
            if (off == pkt.len) break;
            const dst = mem.slice(b.addr, b.len) orelse continue;
            const take = @min(dst.len, pkt.len - off);
            @memcpy(dst[0..take], pkt[off..][0..take]);
            off += take;
        }
        return @intCast(off);
    }
};

fn cast(ptr: *anyopaque) *Net {
    return @ptrCast(@alignCast(ptr));
}

// --- tests -----------------------------------------------------------------
//
// Memory layout in the shared `ram` (guest base 0):
//   TX queue: desc 0x0000, avail 0x0200, used 0x0400
//   RX queue: desc 0x0600, avail 0x0800, used 0x0A00
//   TX packet buffer 0x1000; RX buffer 0x2000 (4 KiB)

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

fn usedIdx(ram: []const u8, used: usize) u16 {
    return std.mem.readInt(u16, ram[used + 2 ..][0..2], .little);
}

const TxSink = struct {
    buf: [FRAME_MAX]u8 = undefined,
    len: usize = 0,
    calls: u32 = 0,
    fn take(ctx: *anyopaque, frame: []const u8) void {
        const self: *TxSink = @ptrCast(@alignCast(ctx));
        @memcpy(self.buf[0..frame.len], frame);
        self.len = frame.len;
        self.calls += 1;
    }
};

test "config exposes the MAC" {
    var ram = [_]u8{0} ** 4096;
    var net = Net{};
    var dev = virtio.Device.init(net.backend(), .{ .bytes = &ram, .base = 0 });
    // mac = 52:54:00:12:34:56. mac[0..4] then mac[4..6] (status zero), LE.
    try testing.expectEqual(@as(u32, 0x12005452), dev.barRead(0x3000, 4));
    try testing.expectEqual(@as(u32, 0x00005634), dev.barRead(0x3004, 4));
}

test "TX strips the header and hands the frame to the host" {
    var ram = [_]u8{0} ** 16384;
    var sink = TxSink{};
    var net = Net{ .on_tx = TxSink.take, .on_tx_ctx = &sink };
    var dev = virtio.Device.init(net.backend(), .{ .bytes = &ram, .base = 0 });
    progQueue(&dev, TXQ, 8, TX_DESC, TX_AVAIL, TX_USED);

    // One readable chain: 12-byte net header then a 6-byte "frame".
    const frame = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x11, 0x22 };
    @memset(ram[0x1000..][0..NET_HDR_LEN], 0);
    @memcpy(ram[0x1000 + NET_HDR_LEN ..][0..frame.len], &frame);
    wdesc(&ram, TX_DESC, 0x1000, NET_HDR_LEN + frame.len, 0, 0);
    std.mem.writeInt(u16, ram[TX_AVAIL + 4 ..][0..2], 0, .little);
    std.mem.writeInt(u16, ram[TX_AVAIL + 2 ..][0..2], 1, .little);

    dev.barWrite(0x2000, 4, TXQ); // kick TX

    try testing.expectEqual(@as(u32, 1), sink.calls);
    try testing.expectEqualSlices(u8, &frame, sink.buf[0..sink.len]);
    try testing.expectEqual(@as(u16, 1), usedIdx(&ram, TX_USED));
    try testing.expect(dev.isr & 1 != 0);
}

test "TX gathers a header/frame split across descriptors" {
    var ram = [_]u8{0} ** 16384;
    var sink = TxSink{};
    var net = Net{ .on_tx = TxSink.take, .on_tx_ctx = &sink };
    var dev = virtio.Device.init(net.backend(), .{ .bytes = &ram, .base = 0 });
    progQueue(&dev, TXQ, 8, TX_DESC, TX_AVAIL, TX_USED);

    // desc0 = header only, desc1 = frame. The device must reassemble.
    const frame = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    @memset(ram[0x1000..][0..NET_HDR_LEN], 0);
    @memcpy(ram[0x1200..][0..frame.len], &frame);
    wdesc(&ram, TX_DESC + 0, 0x1000, NET_HDR_LEN, virtq.DESC_F_NEXT, 1);
    wdesc(&ram, TX_DESC + 16, 0x1200, frame.len, 0, 0);
    std.mem.writeInt(u16, ram[TX_AVAIL + 4 ..][0..2], 0, .little);
    std.mem.writeInt(u16, ram[TX_AVAIL + 2 ..][0..2], 1, .little);

    dev.barWrite(0x2000, 4, TXQ);

    try testing.expectEqual(@as(u32, 1), sink.calls);
    try testing.expectEqualSlices(u8, &frame, sink.buf[0..sink.len]);
}

test "pushRx delivers a frame with a fresh header to the guest" {
    var ram = [_]u8{0} ** 16384;
    var net = Net{};
    var dev = virtio.Device.init(net.backend(), .{ .bytes = &ram, .base = 0 });
    net.attach(&dev);
    progQueue(&dev, RXQ, 8, RX_DESC, RX_AVAIL, RX_USED);

    wdesc(&ram, RX_DESC, 0x2000, 0x1000, virtq.DESC_F_WRITE, 0);
    std.mem.writeInt(u16, ram[RX_AVAIL + 4 ..][0..2], 0, .little);
    std.mem.writeInt(u16, ram[RX_AVAIL + 2 ..][0..2], 1, .little);

    const frame = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee };
    try testing.expect(net.pushRx(&frame));

    try testing.expectEqual(@as(u16, 1), usedIdx(&ram, RX_USED));
    // used length is header + frame.
    try testing.expectEqual(@as(u32, NET_HDR_LEN + frame.len), std.mem.readInt(u32, ram[RX_USED + 8 ..][0..4], .little));
    // header zeroed, num_buffers = 1, frame intact after it.
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ram[0x2000 + NUM_BUFFERS_OFF ..][0..2], .little));
    try testing.expectEqualSlices(u8, &frame, ram[0x2000 + NET_HDR_LEN ..][0..frame.len]);
    try testing.expect(dev.isr & 1 != 0);
}

test "pushRx drops when no RX buffer is posted" {
    var ram = [_]u8{0} ** 16384;
    var net = Net{};
    var dev = virtio.Device.init(net.backend(), .{ .bytes = &ram, .base = 0 });
    net.attach(&dev);
    progQueue(&dev, RXQ, 8, RX_DESC, RX_AVAIL, RX_USED);
    // avail.idx left at 0: no buffer available.
    const frame = [_]u8{ 1, 2, 3 };
    try testing.expect(!net.pushRx(&frame));
    try testing.expectEqual(@as(u16, 0), usedIdx(&ram, RX_USED));
}

test "pushRx drops an oversized frame and is a no-op before attach" {
    var net = Net{};
    const big = [_]u8{0} ** (FRAME_MAX + 1);
    try testing.expect(!net.pushRx(&big)); // not attached and too big
}
