//! virtio-vsock protocol engine: the swerver<->guest channel (the thesis spine).
//!
//! This file is the *pure* protocol core. It parses and emits virtio_vsock
//! packets (a 44-byte header plus payload), runs the per-connection state
//! machine, and does credit-based flow control. It never touches guest memory
//! or a virtqueue: inbound packets arrive as byte slices (the device layer
//! copies them out of the TX ring first) and outbound packets are staged in a
//! fixed ring that the device layer drains onto the RX ring. That keeps the
//! whole protocol testable on the host and serializable for snapshots.
//!
//! The device glue (RX/TX virtqueue plumbing, the virtio.Backend, guest_cid
//! device config) lands in a follow-up chunk; this is the layer it sits on.
//!
//! Single-guest model: the host CID is fixed at 2 and the guest CID is fixed
//! per VM, so a connection is uniquely identified by its (host_port,
//! guest_port) pair. STREAM sockets only.

const std = @import("std");

pub const HOST_CID: u64 = 2;
pub const HDR_LEN = 44;

/// Per-packet payload cap. The guest posts RX buffers at least this large, so
/// one staged packet maps to one RX descriptor chain.
pub const MAX_PAYLOAD = 4096;
const PKT_CAP = HDR_LEN + MAX_PAYLOAD;

/// Outbound staging ring depth and connection table size. Fixed pools (no
/// per-packet allocation) keep the engine snapshot-friendly.
const OUT_RING = 64;
pub const MAX_CONNS = 64;
const MAX_LISTEN = 16;

/// Buffer space we advertise to the guest for each connection (our RX window).
const DEFAULT_BUF_ALLOC: u32 = 64 * 1024;

pub const Type = struct {
    pub const STREAM: u16 = 1;
};

pub const Op = struct {
    pub const INVALID: u16 = 0;
    pub const REQUEST: u16 = 1;
    pub const RESPONSE: u16 = 2;
    pub const RST: u16 = 3;
    pub const SHUTDOWN: u16 = 4;
    pub const RW: u16 = 5;
    pub const CREDIT_UPDATE: u16 = 6;
    pub const CREDIT_REQUEST: u16 = 7;
};

pub const Shutdown = struct {
    pub const RCV: u32 = 1;
    pub const SEND: u32 = 2;
    pub const BOTH: u32 = 3;
};

/// virtio_vsock_hdr, 44 bytes, all fields little-endian. `kind` is the spec's
/// `type` field (renamed to avoid the Zig keyword).
pub const Hdr = struct {
    src_cid: u64 = 0,
    dst_cid: u64 = 0,
    src_port: u32 = 0,
    dst_port: u32 = 0,
    len: u32 = 0,
    kind: u16 = Type.STREAM,
    op: u16 = Op.INVALID,
    flags: u32 = 0,
    buf_alloc: u32 = 0,
    fwd_cnt: u32 = 0,

    pub fn decode(b: []const u8) ?Hdr {
        if (b.len < HDR_LEN) return null;
        return .{
            .src_cid = std.mem.readInt(u64, b[0..8], .little),
            .dst_cid = std.mem.readInt(u64, b[8..16], .little),
            .src_port = std.mem.readInt(u32, b[16..20], .little),
            .dst_port = std.mem.readInt(u32, b[20..24], .little),
            .len = std.mem.readInt(u32, b[24..28], .little),
            .kind = std.mem.readInt(u16, b[28..30], .little),
            .op = std.mem.readInt(u16, b[30..32], .little),
            .flags = std.mem.readInt(u32, b[32..36], .little),
            .buf_alloc = std.mem.readInt(u32, b[36..40], .little),
            .fwd_cnt = std.mem.readInt(u32, b[40..44], .little),
        };
    }

    pub fn encode(self: Hdr, b: []u8) void {
        std.mem.writeInt(u64, b[0..8], self.src_cid, .little);
        std.mem.writeInt(u64, b[8..16], self.dst_cid, .little);
        std.mem.writeInt(u32, b[16..20], self.src_port, .little);
        std.mem.writeInt(u32, b[20..24], self.dst_port, .little);
        std.mem.writeInt(u32, b[24..28], self.len, .little);
        std.mem.writeInt(u16, b[28..30], self.kind, .little);
        std.mem.writeInt(u16, b[30..32], self.op, .little);
        std.mem.writeInt(u32, b[32..36], self.flags, .little);
        std.mem.writeInt(u32, b[36..40], self.buf_alloc, .little);
        std.mem.writeInt(u32, b[40..44], self.fwd_cnt, .little);
    }
};

pub const Conn = struct {
    state: State = .closed,
    host_port: u32 = 0,
    guest_port: u32 = 0,

    // The guest's receive window, as last advertised in a header from it.
    peer_buf_alloc: u32 = 0,
    peer_fwd_cnt: u32 = 0,
    tx_cnt: u32 = 0, // cumulative bytes we have sent to the guest

    // Our receive accounting, advertised back to the guest.
    fwd_cnt: u32 = 0, // cumulative bytes we have consumed from the guest
    buf_alloc: u32 = DEFAULT_BUF_ALLOC,

    pub const State = enum { closed, connecting, established, closing };

    /// Bytes we may still send to the guest before exhausting its window.
    fn txCredit(self: Conn) u32 {
        const in_flight = self.tx_cnt -% self.peer_fwd_cnt;
        if (in_flight >= self.peer_buf_alloc) return 0;
        return self.peer_buf_alloc - in_flight;
    }
};

/// Host-facing event. `bytes` in `recv` is only valid for the duration of the
/// callback (it aliases the inbound packet).
pub const Event = union(enum) {
    accept: u16, // conn id: guest connected to a listened host port
    connected: u16, // conn id: our outbound connect was accepted
    recv: Recv,
    shutdown: u16, // conn id: guest closed
    reset: u16, // conn id: connection reset / refused

    pub const Recv = struct { conn: u16, bytes: []const u8 };
};

const OutPkt = struct {
    len: u32 = 0, // total staged bytes (header + payload)
    buf: [PKT_CAP]u8 = undefined,
};

pub const Vsock = struct {
    guest_cid: u64,
    conns: [MAX_CONNS]Conn = [_]Conn{.{}} ** MAX_CONNS,
    listen_ports: [MAX_LISTEN]u32 = [_]u32{0} ** MAX_LISTEN, // 0 = unused slot

    out: [OUT_RING]OutPkt = [_]OutPkt{.{}} ** OUT_RING,
    out_head: usize = 0,
    out_tail: usize = 0,
    out_count: usize = 0,

    on_event: ?*const fn (ctx: *anyopaque, ev: Event) void = null,
    on_event_ctx: ?*anyopaque = null,

    // --- host-side listen registry -----------------------------------------

    /// Register a host port the guest may connect to. Port 0 is invalid.
    pub fn listen(self: *Vsock, port: u32) bool {
        if (port == 0) return false;
        if (self.isListening(port)) return true;
        for (&self.listen_ports) |*p| {
            if (p.* == 0) {
                p.* = port;
                return true;
            }
        }
        return false;
    }

    pub fn unlisten(self: *Vsock, port: u32) void {
        for (&self.listen_ports) |*p| {
            if (p.* == port) p.* = 0;
        }
    }

    pub fn isListening(self: *Vsock, port: u32) bool {
        for (self.listen_ports) |p| {
            if (p != 0 and p == port) return true;
        }
        return false;
    }

    // --- inbound: a packet the guest sent on its TX queue ------------------

    pub fn rx(self: *Vsock, pkt: []const u8) void {
        const h = Hdr.decode(pkt) orelse return;
        if (h.kind != Type.STREAM) {
            self.sendRst(h);
            return;
        }
        const payload = blk: {
            const want = @min(h.len, MAX_PAYLOAD);
            const avail = pkt.len - HDR_LEN;
            break :blk pkt[HDR_LEN..][0..@min(want, avail)];
        };
        switch (h.op) {
            Op.REQUEST => self.onRequest(h),
            Op.RESPONSE => self.onResponse(h),
            Op.RW => self.onRw(h, payload),
            Op.CREDIT_UPDATE => self.onCreditUpdate(h),
            Op.CREDIT_REQUEST => self.onCreditRequest(h),
            Op.SHUTDOWN => self.onShutdown(h),
            Op.RST => self.onRst(h),
            else => self.sendRst(h),
        }
    }

    fn onRequest(self: *Vsock, h: Hdr) void {
        if (!self.isListening(h.dst_port)) {
            self.sendRst(h);
            return;
        }
        const id = self.findConn(h.dst_port, h.src_port) orelse
            self.allocConn() orelse {
                self.sendRst(h);
                return;
            };
        const c = &self.conns[id];
        c.* = .{
            .state = .established,
            .host_port = h.dst_port,
            .guest_port = h.src_port,
            .peer_buf_alloc = h.buf_alloc,
            .peer_fwd_cnt = h.fwd_cnt,
        };
        self.sendCtl(c, Op.RESPONSE);
        self.fire(.{ .accept = id });
    }

    fn onResponse(self: *Vsock, h: Hdr) void {
        const id = self.findConn(h.dst_port, h.src_port) orelse {
            self.sendRst(h);
            return;
        };
        const c = &self.conns[id];
        if (c.state != .connecting) return;
        c.state = .established;
        c.peer_buf_alloc = h.buf_alloc;
        c.peer_fwd_cnt = h.fwd_cnt;
        self.fire(.{ .connected = id });
    }

    fn onRw(self: *Vsock, h: Hdr, payload: []const u8) void {
        const id = self.findConn(h.dst_port, h.src_port) orelse {
            self.sendRst(h);
            return;
        };
        const c = &self.conns[id];
        if (c.state != .established) {
            self.sendRst(h);
            return;
        }
        c.peer_buf_alloc = h.buf_alloc;
        c.peer_fwd_cnt = h.fwd_cnt;
        if (payload.len > 0) {
            self.fire(.{ .recv = .{ .conn = id, .bytes = payload } });
            c.fwd_cnt +%= @intCast(payload.len); // consumed synchronously
            self.sendCtl(c, Op.CREDIT_UPDATE); // reopen the guest's window
        }
    }

    fn onCreditUpdate(self: *Vsock, h: Hdr) void {
        const id = self.findConn(h.dst_port, h.src_port) orelse return;
        const c = &self.conns[id];
        c.peer_buf_alloc = h.buf_alloc;
        c.peer_fwd_cnt = h.fwd_cnt;
    }

    fn onCreditRequest(self: *Vsock, h: Hdr) void {
        const id = self.findConn(h.dst_port, h.src_port) orelse return;
        self.sendCtl(&self.conns[id], Op.CREDIT_UPDATE);
    }

    fn onShutdown(self: *Vsock, h: Hdr) void {
        const id = self.findConn(h.dst_port, h.src_port) orelse {
            self.sendRst(h);
            return;
        };
        const c = &self.conns[id];
        // Confirm the close with an RST and tear the connection down.
        self.sendCtl(c, Op.RST);
        self.fire(.{ .shutdown = id });
        c.state = .closed;
    }

    fn onRst(self: *Vsock, h: Hdr) void {
        const id = self.findConn(h.dst_port, h.src_port) orelse return;
        const c = &self.conns[id];
        const was_connecting = c.state == .connecting;
        c.state = .closed;
        // A connecting socket that gets RST was refused; report it as a reset.
        _ = was_connecting;
        self.fire(.{ .reset = id });
    }

    // --- host actions ------------------------------------------------------

    /// Open a connection from the host to a guest port. Returns the conn id, or
    /// null if the connection table is full.
    pub fn connect(self: *Vsock, host_port: u32, guest_port: u32) ?u16 {
        const id = self.allocConn() orelse return null;
        const c = &self.conns[id];
        c.* = .{
            .state = .connecting,
            .host_port = host_port,
            .guest_port = guest_port,
        };
        self.sendCtl(c, Op.REQUEST);
        return id;
    }

    /// Send host->guest data on an established connection. Honors the guest's
    /// credit window and the staging ring; returns the number of bytes accepted
    /// (a short count means retry later, after a CREDIT_UPDATE or a drain).
    pub fn send(self: *Vsock, id: u16, data: []const u8) usize {
        if (id >= MAX_CONNS) return 0;
        const c = &self.conns[id];
        if (c.state != .established) return 0;
        var sent: usize = 0;
        while (sent < data.len) {
            const credit = c.txCredit();
            if (credit == 0) break;
            const chunk = @min(@min(data.len - sent, MAX_PAYLOAD), credit);
            const h = self.hdrFor(c, Op.RW, @intCast(chunk));
            if (!self.pushOut(h, data[sent..][0..chunk])) break; // ring full
            c.tx_cnt +%= @intCast(chunk);
            sent += chunk;
        }
        return sent;
    }

    /// Close a connection from the host side (graceful shutdown both ways).
    pub fn close(self: *Vsock, id: u16) void {
        if (id >= MAX_CONNS) return;
        const c = &self.conns[id];
        if (c.state == .closed) return;
        var h = self.hdrFor(c, Op.SHUTDOWN, 0);
        h.flags = Shutdown.BOTH;
        _ = self.pushOut(h, &.{});
        c.state = .closing;
    }

    // --- outbound staging ring (drained by the device layer) ---------------

    pub fn pendingOut(self: *Vsock) bool {
        return self.out_count > 0;
    }

    /// The next staged packet (header + payload), or null. Valid until popOut.
    pub fn peekOut(self: *Vsock) ?[]const u8 {
        if (self.out_count == 0) return null;
        const s = &self.out[self.out_head];
        return s.buf[0..s.len];
    }

    pub fn popOut(self: *Vsock) void {
        if (self.out_count == 0) return;
        self.out_head = (self.out_head + 1) % OUT_RING;
        self.out_count -= 1;
    }

    // --- device config -----------------------------------------------------

    /// virtio_vsock_config: guest_cid is a u64 at offset 0.
    pub fn configRead(self: *Vsock, off: u16, size: u8) u32 {
        _ = size;
        return switch (off) {
            0 => @truncate(self.guest_cid),
            4 => @truncate(self.guest_cid >> 32),
            else => 0,
        };
    }

    // --- internals ---------------------------------------------------------

    fn hdrFor(self: *Vsock, c: *const Conn, op: u16, len: u32) Hdr {
        return .{
            .src_cid = HOST_CID,
            .dst_cid = self.guest_cid,
            .src_port = c.host_port,
            .dst_port = c.guest_port,
            .len = len,
            .kind = Type.STREAM,
            .op = op,
            .buf_alloc = c.buf_alloc,
            .fwd_cnt = c.fwd_cnt,
        };
    }

    fn sendCtl(self: *Vsock, c: *const Conn, op: u16) void {
        _ = self.pushOut(self.hdrFor(c, op, 0), &.{});
    }

    /// Reply RST to a packet we cannot service, swapping its ports.
    fn sendRst(self: *Vsock, h: Hdr) void {
        if (h.op == Op.RST) return; // never answer an RST with an RST
        const r = Hdr{
            .src_cid = HOST_CID,
            .dst_cid = self.guest_cid,
            .src_port = h.dst_port,
            .dst_port = h.src_port,
            .kind = Type.STREAM,
            .op = Op.RST,
        };
        _ = self.pushOut(r, &.{});
    }

    fn pushOut(self: *Vsock, h: Hdr, payload: []const u8) bool {
        if (self.out_count == OUT_RING) return false;
        const s = &self.out[self.out_tail];
        h.encode(s.buf[0..HDR_LEN]);
        const n = @min(payload.len, MAX_PAYLOAD);
        if (n > 0) @memcpy(s.buf[HDR_LEN..][0..n], payload[0..n]);
        s.len = HDR_LEN + @as(u32, @intCast(n));
        self.out_tail = (self.out_tail + 1) % OUT_RING;
        self.out_count += 1;
        return true;
    }

    fn findConn(self: *Vsock, host_port: u32, guest_port: u32) ?u16 {
        for (&self.conns, 0..) |*c, i| {
            if (c.state != .closed and c.host_port == host_port and c.guest_port == guest_port)
                return @intCast(i);
        }
        return null;
    }

    fn allocConn(self: *Vsock) ?u16 {
        for (&self.conns, 0..) |*c, i| {
            if (c.state == .closed) return @intCast(i);
        }
        return null;
    }

    fn fire(self: *Vsock, ev: Event) void {
        if (self.on_event) |f| f(self.on_event_ctx.?, ev);
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// Collects events and lets a test pull staged outbound packets back as Hdrs.
const Recorder = struct {
    events: std.ArrayList(Event) = .empty,
    last_recv: [MAX_PAYLOAD]u8 = undefined,
    last_recv_len: usize = 0,

    fn sink(ctx: *anyopaque, ev: Event) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (ev == .recv) {
            const b = ev.recv.bytes;
            @memcpy(self.last_recv[0..b.len], b);
            self.last_recv_len = b.len;
        }
        self.events.append(testing.allocator, ev) catch unreachable;
    }

    fn deinit(self: *Recorder) void {
        self.events.deinit(testing.allocator);
    }
};

fn drainHdrs(vs: *Vsock, out: []Hdr) usize {
    var n: usize = 0;
    while (vs.peekOut()) |pkt| {
        if (n < out.len) out[n] = Hdr.decode(pkt).?;
        n += 1;
        vs.popOut();
    }
    return n;
}

fn guestPkt(buf: []u8, h: Hdr, payload: []const u8) []const u8 {
    h.encode(buf[0..HDR_LEN]);
    @memcpy(buf[HDR_LEN..][0..payload.len], payload);
    return buf[0 .. HDR_LEN + payload.len];
}

test "header round-trips through encode/decode" {
    const h = Hdr{
        .src_cid = 2,
        .dst_cid = 3,
        .src_port = 1024,
        .dst_port = 5555,
        .len = 12,
        .kind = Type.STREAM,
        .op = Op.RW,
        .flags = 3,
        .buf_alloc = 65536,
        .fwd_cnt = 99,
    };
    var buf: [HDR_LEN]u8 = undefined;
    h.encode(&buf);
    const d = Hdr.decode(&buf).?;
    try testing.expectEqual(h, d);
    try testing.expect(Hdr.decode(buf[0 .. HDR_LEN - 1]) == null); // short
}

test "REQUEST to a listened port establishes and emits RESPONSE" {
    var vs = Vsock{ .guest_cid = 3 };
    var rec = Recorder{};
    defer rec.deinit();
    vs.on_event = Recorder.sink;
    vs.on_event_ctx = &rec;
    try testing.expect(vs.listen(5555));

    var pbuf: [HDR_LEN]u8 = undefined;
    const req = guestPkt(&pbuf, .{
        .src_cid = 3,
        .dst_cid = HOST_CID,
        .src_port = 1024,
        .dst_port = 5555,
        .op = Op.REQUEST,
        .buf_alloc = 4096,
    }, &.{});
    vs.rx(req);

    try testing.expectEqual(@as(usize, 1), rec.events.items.len);
    try testing.expect(rec.events.items[0] == .accept);
    const id = rec.events.items[0].accept;
    try testing.expectEqual(Conn.State.established, vs.conns[id].state);
    try testing.expectEqual(@as(u32, 4096), vs.conns[id].peer_buf_alloc);

    var hdrs: [4]Hdr = undefined;
    try testing.expectEqual(@as(usize, 1), drainHdrs(&vs, &hdrs));
    try testing.expectEqual(Op.RESPONSE, hdrs[0].op);
    try testing.expectEqual(@as(u32, 5555), hdrs[0].src_port); // host side
    try testing.expectEqual(@as(u32, 1024), hdrs[0].dst_port); // guest side
    try testing.expectEqual(HOST_CID, hdrs[0].src_cid);
    try testing.expectEqual(@as(u64, 3), hdrs[0].dst_cid);
}

test "REQUEST to an unlistened port is refused with RST" {
    var vs = Vsock{ .guest_cid = 3 };
    var pbuf: [HDR_LEN]u8 = undefined;
    const req = guestPkt(&pbuf, .{
        .src_cid = 3,
        .dst_cid = HOST_CID,
        .src_port = 1024,
        .dst_port = 9999,
        .op = Op.REQUEST,
    }, &.{});
    vs.rx(req);
    var hdrs: [4]Hdr = undefined;
    try testing.expectEqual(@as(usize, 1), drainHdrs(&vs, &hdrs));
    try testing.expectEqual(Op.RST, hdrs[0].op);
    try testing.expectEqual(@as(u32, 9999), hdrs[0].src_port); // ports swapped
    try testing.expectEqual(@as(u32, 1024), hdrs[0].dst_port);
}

test "RW delivers payload and emits a credit update" {
    var vs = Vsock{ .guest_cid = 3 };
    var rec = Recorder{};
    defer rec.deinit();
    vs.on_event = Recorder.sink;
    vs.on_event_ctx = &rec;
    _ = vs.listen(7);

    var pbuf: [HDR_LEN]u8 = undefined;
    vs.rx(guestPkt(&pbuf, .{ .src_cid = 3, .dst_cid = HOST_CID, .src_port = 50, .dst_port = 7, .op = Op.REQUEST, .buf_alloc = 8192 }, &.{}));
    var hdrs: [4]Hdr = undefined;
    _ = drainHdrs(&vs, &hdrs); // discard RESPONSE
    const id = vs.findConn(7, 50).?;

    var dbuf: [HDR_LEN + 5]u8 = undefined;
    vs.rx(guestPkt(&dbuf, .{ .src_cid = 3, .dst_cid = HOST_CID, .src_port = 50, .dst_port = 7, .op = Op.RW, .len = 5, .buf_alloc = 8192, .fwd_cnt = 0 }, "hello"));

    try testing.expectEqual(@as(usize, 5), rec.last_recv_len);
    try testing.expectEqualStrings("hello", rec.last_recv[0..5]);
    try testing.expectEqual(@as(u32, 5), vs.conns[id].fwd_cnt);

    try testing.expectEqual(@as(usize, 1), drainHdrs(&vs, &hdrs));
    try testing.expectEqual(Op.CREDIT_UPDATE, hdrs[0].op);
    try testing.expectEqual(@as(u32, 5), hdrs[0].fwd_cnt);
}

test "host send respects the guest credit window" {
    var vs = Vsock{ .guest_cid = 3 };
    _ = vs.listen(7);
    var pbuf: [HDR_LEN]u8 = undefined;
    // Guest advertises only 4 bytes of receive space.
    vs.rx(guestPkt(&pbuf, .{ .src_cid = 3, .dst_cid = HOST_CID, .src_port = 50, .dst_port = 7, .op = Op.REQUEST, .buf_alloc = 4 }, &.{}));
    var hdrs: [8]Hdr = undefined;
    _ = drainHdrs(&vs, &hdrs); // discard RESPONSE
    const id = vs.findConn(7, 50).?;

    // Only 4 of 10 bytes fit in the window.
    try testing.expectEqual(@as(usize, 4), vs.send(id, "0123456789"));
    try testing.expectEqual(@as(u32, 4), vs.conns[id].tx_cnt);

    // The guest consumes 4 bytes and reopens its window via CREDIT_UPDATE.
    vs.rx(guestPkt(&pbuf, .{ .src_cid = 3, .dst_cid = HOST_CID, .src_port = 50, .dst_port = 7, .op = Op.CREDIT_UPDATE, .buf_alloc = 4, .fwd_cnt = 4 }, &.{}));
    try testing.expectEqual(@as(usize, 4), vs.send(id, "456789"));
    try testing.expectEqual(@as(u32, 8), vs.conns[id].tx_cnt);
}

test "host send chunks large writes by MAX_PAYLOAD" {
    var vs = Vsock{ .guest_cid = 3 };
    _ = vs.listen(7);
    var pbuf: [HDR_LEN]u8 = undefined;
    vs.rx(guestPkt(&pbuf, .{ .src_cid = 3, .dst_cid = HOST_CID, .src_port = 50, .dst_port = 7, .op = Op.REQUEST, .buf_alloc = 1 << 20 }, &.{}));
    var sink: [4]Hdr = undefined;
    _ = drainHdrs(&vs, &sink);
    const id = vs.findConn(7, 50).?;

    const big = [_]u8{0xab} ** (MAX_PAYLOAD + 100);
    try testing.expectEqual(@as(usize, MAX_PAYLOAD + 100), vs.send(id, &big));

    // Two staged RW packets: a full one and a remainder.
    try testing.expect(vs.peekOut() != null);
    const p0 = Hdr.decode(vs.peekOut().?).?;
    try testing.expectEqual(@as(u32, MAX_PAYLOAD), p0.len);
    vs.popOut();
    const p1 = Hdr.decode(vs.peekOut().?).?;
    try testing.expectEqual(@as(u32, 100), p1.len);
}

test "guest SHUTDOWN tears down and confirms with RST" {
    var vs = Vsock{ .guest_cid = 3 };
    var rec = Recorder{};
    defer rec.deinit();
    vs.on_event = Recorder.sink;
    vs.on_event_ctx = &rec;
    _ = vs.listen(7);
    var pbuf: [HDR_LEN]u8 = undefined;
    vs.rx(guestPkt(&pbuf, .{ .src_cid = 3, .dst_cid = HOST_CID, .src_port = 50, .dst_port = 7, .op = Op.REQUEST }, &.{}));
    var hdrs: [4]Hdr = undefined;
    _ = drainHdrs(&vs, &hdrs);
    const id = vs.findConn(7, 50).?;

    vs.rx(guestPkt(&pbuf, .{ .src_cid = 3, .dst_cid = HOST_CID, .src_port = 50, .dst_port = 7, .op = Op.SHUTDOWN, .flags = Shutdown.BOTH }, &.{}));
    try testing.expectEqual(Conn.State.closed, vs.conns[id].state);
    try testing.expect(rec.events.items[rec.events.items.len - 1] == .shutdown);
    try testing.expectEqual(@as(usize, 1), drainHdrs(&vs, &hdrs));
    try testing.expectEqual(Op.RST, hdrs[0].op);
}

test "host connect emits REQUEST and RESPONSE establishes it" {
    var vs = Vsock{ .guest_cid = 3 };
    var rec = Recorder{};
    defer rec.deinit();
    vs.on_event = Recorder.sink;
    vs.on_event_ctx = &rec;

    const id = vs.connect(40000, 22).?;
    try testing.expectEqual(Conn.State.connecting, vs.conns[id].state);
    var hdrs: [4]Hdr = undefined;
    try testing.expectEqual(@as(usize, 1), drainHdrs(&vs, &hdrs));
    try testing.expectEqual(Op.REQUEST, hdrs[0].op);
    try testing.expectEqual(@as(u32, 40000), hdrs[0].src_port);
    try testing.expectEqual(@as(u32, 22), hdrs[0].dst_port);

    var pbuf: [HDR_LEN]u8 = undefined;
    // Guest accepts: src=guest port 22, dst=host port 40000.
    vs.rx(guestPkt(&pbuf, .{ .src_cid = 3, .dst_cid = HOST_CID, .src_port = 22, .dst_port = 40000, .op = Op.RESPONSE, .buf_alloc = 16384 }, &.{}));
    try testing.expectEqual(Conn.State.established, vs.conns[id].state);
    try testing.expect(rec.events.items[rec.events.items.len - 1] == .connected);
}

test "RW on an unknown connection is refused with RST" {
    var vs = Vsock{ .guest_cid = 3 };
    var dbuf: [HDR_LEN + 3]u8 = undefined;
    vs.rx(guestPkt(&dbuf, .{ .src_cid = 3, .dst_cid = HOST_CID, .src_port = 1, .dst_port = 2, .op = Op.RW, .len = 3 }, "abc"));
    var hdrs: [4]Hdr = undefined;
    try testing.expectEqual(@as(usize, 1), drainHdrs(&vs, &hdrs));
    try testing.expectEqual(Op.RST, hdrs[0].op);
}

test "a lying length field cannot over-read the packet buffer" {
    var vs = Vsock{ .guest_cid = 3 };
    var rec = Recorder{};
    defer rec.deinit();
    vs.on_event = Recorder.sink;
    vs.on_event_ctx = &rec;
    _ = vs.listen(7);
    var pbuf: [HDR_LEN]u8 = undefined;
    vs.rx(guestPkt(&pbuf, .{ .src_cid = 3, .dst_cid = HOST_CID, .src_port = 50, .dst_port = 7, .op = Op.REQUEST }, &.{}));
    var sink: [4]Hdr = undefined;
    _ = drainHdrs(&vs, &sink);

    // len claims 1000 bytes but only 4 follow the header.
    var dbuf: [HDR_LEN + 4]u8 = undefined;
    vs.rx(guestPkt(&dbuf, .{ .src_cid = 3, .dst_cid = HOST_CID, .src_port = 50, .dst_port = 7, .op = Op.RW, .len = 1000 }, "data"));
    try testing.expectEqual(@as(usize, 4), rec.last_recv_len); // clamped to what arrived
}
