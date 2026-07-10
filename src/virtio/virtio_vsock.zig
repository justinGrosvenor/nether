//! virtio-vsock: the swerver<->guest channel (the thesis spine).
//!
//! Two layers live here:
//!
//!   * `Vsock` is the *pure* protocol engine. It parses and emits virtio_vsock
//!     packets (a 44-byte header plus payload), runs the per-connection state
//!     machine, and does credit-based flow control. It never touches guest
//!     memory or a virtqueue: inbound packets arrive as byte slices and
//!     outbound packets are staged in a fixed ring. That keeps the protocol
//!     testable on the host and serializable for snapshots.
//!
//!   * `VsockDev` is the device glue: a `virtio.Backend` over three virtqueues
//!     (RX=0, TX=1, event=2) that copies guest TX packets into the engine and
//!     drains the engine's staged output back onto the guest's RX buffers. It
//!     carries the D3 per-device lock because, unlike virtio-blk, it is driven
//!     from two threads: the vCPU thread (queue kicks) and the host thread
//!     (swerver staging output via hostSend/hostConnect/hostClose).
//!
//! Single-guest model: the host CID is fixed at 2 and the guest CID is fixed
//! per VM, so a connection is uniquely identified by its (host_port,
//! guest_port) pair. STREAM sockets only.

const std = @import("std");
const virtio = @import("virtio.zig");
const virtq = @import("virtq.zig");
const Lock = @import("../common/lock.zig").Lock;
const trace = @import("../common/trace.zig");

pub const HOST_CID: u64 = 2;
pub const HDR_LEN = 44;

/// Per-packet payload cap. A staged packet (HDR_LEN + payload) must fit in ONE
/// guest RX descriptor chain, or `scatter` truncates it and the guest drops the
/// short packet (which silently stalled multi-packet transfers). The Linux guest's
/// virtio-vsock RX buffers were measured at 3776 bytes of writable capacity, so
/// keep HDR_LEN + MAX_PAYLOAD comfortably under that.
pub const MAX_PAYLOAD = 3072;
const PKT_CAP = HDR_LEN + MAX_PAYLOAD;

/// Outbound staging ring depth and connection table size. Fixed pools (no per-packet
/// allocation) keep the engine snapshot-friendly. NOTE: these sizes are part of the snapshot
/// ABI - `Vsock.State` is raw-copied into the snapshot and its `@sizeOf` is a layout
/// fingerprint (snapshot.zig validateHeader), so changing any of them requires re-baking
/// existing base snapshots (a restore of an old base then fails closed with a clear message,
/// never a silent misrestore): the format is versioned and fails closed on mismatch.
const OUT_RING = 64;
pub const MAX_CONNS = 64;
const MAX_LISTEN = 16;

/// Buffer space we advertise to the guest for each connection (our RX window).
/// We consume guest->host payload synchronously (the event handler copies it out
/// immediately), so this window is effectively unbounded; we advertise a large
/// value so a big single transfer (a __get__ artifact pull) never stalls waiting
/// for a per-packet credit update to make it back through the RX ring.
const DEFAULT_BUF_ALLOC: u32 = 32 * 1024 * 1024;

/// Largest guest->host packet we accept whole. The guest may coalesce its stream
/// into packets up to VIRTIO_VSOCK_MAX_PKT_BUF_SIZE (64 KiB), independent of our
/// (smaller) host->guest MAX_PAYLOAD. The RX scratch must hold one such packet or
/// `gather` would truncate it and silently lose bytes mid-stream.
const RX_MAX_PAYLOAD = 64 * 1024;
const RX_PKT_CAP = HDR_LEN + RX_MAX_PAYLOAD;

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
    // Flow control: when true, onRw does NOT auto-credit on receipt; the caller credits
    // (creditRecv) only as it DELIVERS the bytes, so a slow consumer backpressures the guest.
    defer_credit: bool = false,
    credit_acc: u32 = 0, // delivered bytes accrued since the last CREDIT_UPDATE (coalescing)

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

    // Accept-side flow-control policy (host config, deliberately NOT in State - the setup
    // code re-applies it on restore): conns the GUEST opens to this host port get a bounded
    // receive window + credit-on-delivery, so a bridge with a fixed delivery ring can
    // backpressure the guest. Mirror of connectWindow for host-dialed conns. Must take
    // effect in onRequest BEFORE the RESPONSE header goes out (it advertises buf_alloc).
    accept_defer_port: u32 = 0, // 0 = no port gets the treatment
    accept_defer_window: u32 = 0,

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
            const avail = pkt.len - HDR_LEN; // bounded by RX scratch (RX_PKT_CAP)
            break :blk pkt[HDR_LEN..][0..@min(@as(usize, h.len), avail)];
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
        // A REQUEST whose (dst,src) pair already maps to a LIVE conn is a duplicate or a
        // hostile repeat: findConn only ever returns non-closed slots, so re-establishing
        // here would re-fire .accept and mint a SECOND data-plane bridge entry (orphaned
        // pump thread + fd + delivery buffer) aliasing one engine conn. Ignore it - the
        // connection already exists. A legitimate reconnect uses a fresh guest port and so
        // allocates a new slot below. (Mirrors onResponse's guard against duplicate RESPONSE.)
        if (self.findConn(h.dst_port, h.src_port) != null) return;
        const id = self.allocConn() orelse {
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
        if (self.accept_defer_port != 0 and h.dst_port == self.accept_defer_port) {
            c.buf_alloc = self.accept_defer_window; // advertised in the RESPONSE below
            c.defer_credit = true; // the bridge credits only as it DELIVERS
        }
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
            if (!c.defer_credit) {
                c.fwd_cnt +%= @intCast(payload.len); // consumed synchronously
                self.sendCtl(c, Op.CREDIT_UPDATE); // reopen the guest's window
            }
            // deferred-credit conns (data plane): the handler buffers the payload and credits
            // via creditRecv only as it delivers, so a slow consumer backpressures the guest.
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

    /// Like connect(), but with a BOUNDED RX window and deferred crediting: the guest may
    /// have only `window` bytes in flight before it blocks, and we credit it back only as we
    /// DELIVER (creditRecv) - real backpressure for a slow consumer (the data-plane bridge).
    pub fn connectWindow(self: *Vsock, host_port: u32, guest_port: u32, window: u32) ?u16 {
        const id = self.allocConn() orelse return null;
        const c = &self.conns[id];
        c.* = .{ .state = .connecting, .host_port = host_port, .guest_port = guest_port, .buf_alloc = window, .defer_credit = true };
        self.sendCtl(c, Op.REQUEST);
        return id;
    }

    /// Credit the guest for `n` bytes now DELIVERED on a deferred-credit conn. fwd_cnt is
    /// cumulative, so we COALESCE: emit one CREDIT_UPDATE per quarter-window accrued (one
    /// per packet would flood the shared OUT ring and drop credits, throttling the guest;
    /// the guest still keeps >= 3/4 of its window open between updates). No-op if gone.
    pub fn creditRecv(self: *Vsock, id: u16, n: u32) void {
        if (id >= MAX_CONNS or n == 0) return;
        const c = &self.conns[id];
        if (c.state != .established) return;
        c.fwd_cnt +%= n;
        c.credit_acc += n;
        if (c.credit_acc * 4 >= c.buf_alloc) {
            self.sendCtl(c, Op.CREDIT_UPDATE);
            c.credit_acc = 0;
        }
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

    // --- snapshot (pointer-free engine state) ------------------------------

    /// The serializable engine state: every field EXCEPT the callback pointers
    /// (`on_event`/`on_event_ctx`), which are re-wired by the caller after import.
    /// The fixed-pool design (no heap, no per-connection allocation) makes this a
    /// plain value copy, so a snapshot-forked sandbox can resume an in-flight agent
    /// connection rather than tear it down and reconnect.
    pub const State = struct {
        guest_cid: u64 = 0,
        conns: [MAX_CONNS]Conn = [_]Conn{.{}} ** MAX_CONNS,
        listen_ports: [MAX_LISTEN]u32 = [_]u32{0} ** MAX_LISTEN,
        out: [OUT_RING]OutPkt = [_]OutPkt{.{}} ** OUT_RING,
        out_head: usize = 0,
        out_tail: usize = 0,
        out_count: usize = 0,
    };

    /// Capture the engine state for a snapshot (callbacks excluded).
    pub fn exportState(self: *const Vsock) State {
        return .{
            .guest_cid = self.guest_cid,
            .conns = self.conns,
            .listen_ports = self.listen_ports,
            .out = self.out,
            .out_head = self.out_head,
            .out_tail = self.out_tail,
            .out_count = self.out_count,
        };
    }

    /// Validate engine state read from an operator-supplied snapshot file BEFORE it is
    /// imported, so a truncated / bit-flipped / version-drifted base cannot drive the
    /// host out of bounds. The staging ring indices feed direct `out[...]` array access
    /// in peekOut/pushOut, and each `len` slices `buf[0..len]`, so an out-of-range value
    /// would be a host OOB read/write. The connection table is bounded by construction
    /// (a fixed `[MAX_CONNS]Conn`, byte-copied), and `Conn.state` is a u2-backed enum, so
    /// no entry there can point out of bounds; only the ring needs checking.
    pub fn validState(s: *const State) bool {
        if (s.out_head >= OUT_RING or s.out_tail >= OUT_RING or s.out_count > OUT_RING) return false;
        for (s.out) |pkt| {
            if (pkt.len > PKT_CAP) return false;
        }
        return true;
    }

    /// Reload engine state from a snapshot. Callbacks are NOT touched - the caller
    /// re-wires `on_event`/`on_event_ctx` to the new process's handlers. The caller must
    /// have accepted `validState` first (a corrupt ring would otherwise OOB at drain).
    pub fn importState(self: *Vsock, s: *const State) void {
        self.guest_cid = s.guest_cid;
        self.conns = s.conns;
        self.listen_ports = s.listen_ports;
        self.out = s.out;
        self.out_head = s.out_head;
        self.out_tail = s.out_tail;
        self.out_count = s.out_count;
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

// --- device glue -----------------------------------------------------------

pub const VIRTIO_ID_VSOCK = 19;
pub const RXQ: u16 = 0; // host -> guest (device-initiated)
pub const TXQ: u16 = 1; // guest -> host
pub const EVQ: u16 = 2; // transport events (unused)

/// Wraps the pure engine as a virtio device. Owns the D3 per-device lock that
/// serializes the two threads that touch the engine and the queues: the vCPU
/// thread (queue kicks, via `onNotify`) and the host thread (swerver, via the
/// `host*` methods). The lock is never held across the MSI signal, matching the
/// serial/IOAPIC discipline (interrupts are raised after unlocking).
///
/// Re-entrancy contract: the engine's `on_event` callback only ever fires from
/// inside `engine.rx()`, which `VsockDev` only calls while holding the lock.
/// So an event handler must NOT call the `host*` methods (it would deadlock on
/// the non-recursive lock); to reply inline it calls the engine directly
/// (`engine.send`/`engine.close`) - it is already serialized, and the kick that
/// delivered the event flushes the staged reply to the guest before returning.
pub const VsockDev = struct {
    engine: *Vsock,
    dev: *virtio.Device = undefined,
    attached: bool = false,
    lock: Lock = .{},
    scratch: [RX_PKT_CAP]u8 = undefined, // a guest TX chain gathered contiguously (RX direction)

    pub fn backend(self: *VsockDev) virtio.Backend {
        return .{
            .ptr = self,
            .device_id = VIRTIO_ID_VSOCK,
            .num_queues = 3,
            .device_features = 0,
            .notify = onNotify,
            .config_read = configRead,
        };
    }

    /// Bind the transport so the host thread can push to the guest between
    /// kicks. Call once, after the transport `Device` is created.
    pub fn attach(self: *VsockDev, dev: *virtio.Device) void {
        self.dev = dev;
        self.attached = true;
    }

    fn configRead(ptr: *anyopaque, off: u16, size: u8) u32 {
        return cast(ptr).engine.configRead(off, size);
    }

    fn onNotify(ptr: *anyopaque, dev: *virtio.Device, q: u16) void {
        const self = cast(ptr);
        self.dev = dev;
        self.attached = true;
        switch (q) {
            TXQ => self.handleTx(dev),
            RXQ => self.flush(), // guest replenished RX buffers; push pending
            else => {}, // event queue: unused
        }
    }

    /// vCPU thread: drain the guest's TX ring into the engine, then push any
    /// output the engine staged (RESPONSE/CREDIT_UPDATE/RST, or an inline reply
    /// from an event handler) back to the guest.
    fn handleTx(self: *VsockDev, dev: *virtio.Device) void {
        const mem = dev.memory();
        const vq = dev.queue(TXQ);
        self.lock.lock();
        var consumed = false;
        while (vq.next(mem)) |head| {
            const n = self.gather(mem, vq, head);
            trace.log("vsock tx head={d} len={d}", .{ head, n });
            self.engine.rx(self.scratch[0..n]);
            vq.complete(mem, head, 0); // TX buffers are device-read-only
            consumed = true;
        }
        const delivered = self.drainToRx(dev);
        self.lock.unlock();
        if (consumed) dev.interruptQueue(TXQ);
        if (delivered) dev.interruptQueue(RXQ);
    }

    /// Host thread (or an RX kick): push staged output onto the guest's RX
    /// buffers. Safe to call before `attach` (no-op) so the host can fire it
    /// freely after staging.
    pub fn flush(self: *VsockDev) void {
        if (!self.attached) return;
        const dev = self.dev;
        self.lock.lock();
        const delivered = self.drainToRx(dev);
        self.lock.unlock();
        if (delivered) dev.interruptQueue(RXQ);
    }

    // --- host-facing API (locks; call from swerver's thread, NOT an event
    // callback - see the re-entrancy contract above) ------------------------

    pub fn hostListen(self: *VsockDev, port: u32) bool {
        self.lock.lock();
        defer self.lock.unlock();
        return self.engine.listen(port);
    }

    /// Listen on a host port whose ACCEPTED conns get a bounded window + deferred credit
    /// (the egress bridge: guest-dialed conns delivered through a fixed ring). Config is
    /// not snapshot state - the restore path re-calls this.
    pub fn hostListenWindow(self: *VsockDev, port: u32, window: u32) bool {
        self.lock.lock();
        defer self.lock.unlock();
        self.engine.accept_defer_port = port;
        self.engine.accept_defer_window = window;
        return self.engine.listen(port);
    }

    /// Collect the ids of established conns on host port `port` (restore rehydration:
    /// parked egress conns survive the snapshot and need their host side re-attached).
    pub fn hostConnsOnPort(self: *VsockDev, port: u32, out: []u16) usize {
        self.lock.lock();
        defer self.lock.unlock();
        var n: usize = 0;
        for (&self.engine.conns, 0..) |*c, i| {
            if (n == out.len) break;
            if (c.state == .established and c.host_port == port) {
                out[n] = @intCast(i);
                n += 1;
            }
        }
        return n;
    }

    pub fn hostConnect(self: *VsockDev, host_port: u32, guest_port: u32) ?u16 {
        self.lock.lock();
        const id = self.engine.connect(host_port, guest_port);
        self.lock.unlock();
        self.flush();
        return id;
    }

    pub fn hostSend(self: *VsockDev, id: u16, data: []const u8) usize {
        self.lock.lock();
        const n = self.engine.send(id, data);
        self.lock.unlock();
        self.flush();
        return n;
    }

    /// Host thread: open a bounded-window, deferred-credit conn (data-plane bridge).
    pub fn hostConnectWindow(self: *VsockDev, host_port: u32, guest_port: u32, window: u32) ?u16 {
        self.lock.lock();
        const id = self.engine.connectWindow(host_port, guest_port, window);
        self.lock.unlock();
        self.flush();
        return id;
    }

    /// Host thread: credit `n` delivered bytes back to a deferred-credit conn (reopen window).
    pub fn hostCredit(self: *VsockDev, id: u16, n: u32) void {
        self.lock.lock();
        self.engine.creditRecv(id, n);
        self.lock.unlock();
        self.flush();
    }

    pub fn hostClose(self: *VsockDev, id: u16) void {
        self.lock.lock();
        self.engine.close(id);
        self.lock.unlock();
        self.flush();
    }

    // --- internals (assume the lock is held) -------------------------------

    /// Gather a guest TX chain's device-readable bytes into `scratch`, capped at
    /// the buffer. Returns the contiguous length the engine should parse.
    fn gather(self: *VsockDev, mem: virtq.GuestMem, vq: *virtq.Virtqueue, head: u16) usize {
        var n: usize = 0;
        var it = vq.chain(mem, head);
        while (it.next()) |b| {
            if (b.writable) continue; // device writes those; TX is read-only
            const src = mem.slice(b.addr, b.len) orelse continue;
            const take = @min(self.scratch.len - n, src.len);
            @memcpy(self.scratch[n..][0..take], src[0..take]);
            n += take;
            if (n == self.scratch.len) break;
        }
        return n;
    }

    /// Move staged packets onto available RX chains until one side runs dry.
    /// Returns true if at least one packet was delivered.
    fn drainToRx(self: *VsockDev, dev: *virtio.Device) bool {
        const mem = dev.memory();
        const vq = dev.queue(RXQ);
        var delivered = false;
        while (self.engine.peekOut()) |pkt| {
            if (!vq.hasNext(mem)) break; // no RX buffer to place it in
            const head = vq.next(mem).?;
            const written = scatter(mem, vq, head, pkt);
            vq.complete(mem, head, written);
            trace.log("vsock rx head={d} len={d}", .{ head, written });
            self.engine.popOut();
            delivered = true;
        }
        return delivered;
    }

    /// Copy a staged packet across an RX chain's device-writable buffers.
    fn scatter(mem: virtq.GuestMem, vq: *virtq.Virtqueue, head: u16, pkt: []const u8) u32 {
        var off: usize = 0;
        var it = vq.chain(mem, head);
        while (it.next()) |b| {
            if (!b.writable) continue; // RX buffers must be device-writable
            if (off == pkt.len) break;
            const dst = mem.slice(b.addr, b.len) orelse continue;
            const take = @min(dst.len, pkt.len - off);
            @memcpy(dst[0..take], pkt[off..][0..take]);
            off += take;
        }
        return @intCast(off);
    }
};

fn cast(ptr: *anyopaque) *VsockDev {
    return @ptrCast(@alignCast(ptr));
}

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

test "engine state round-trips so a forked connection survives" {
    var vs = Vsock{ .guest_cid = 3 };
    var rec = Recorder{};
    defer rec.deinit();
    vs.on_event = Recorder.sink;
    vs.on_event_ctx = &rec;
    _ = vs.listen(5000);
    var pbuf: [HDR_LEN]u8 = undefined;
    // Establish a connection and stage an outbound packet, as at a snapshot point.
    vs.rx(guestPkt(&pbuf, .{ .src_cid = 3, .dst_cid = HOST_CID, .src_port = 50, .dst_port = 5000, .op = Op.REQUEST, .buf_alloc = 65536 }, &.{}));
    const id = vs.findConn(5000, 50).?;
    try testing.expectEqual(@as(usize, 4), vs.send(id, "ping"));

    // Export, then import into a fresh engine in a "new process" (callbacks re-wired).
    const saved = vs.exportState();
    var vs2 = Vsock{ .guest_cid = 0 };
    var rec2 = Recorder{};
    defer rec2.deinit();
    vs2.importState(&saved);
    vs2.on_event = Recorder.sink;
    vs2.on_event_ctx = &rec2;

    // The surviving connection is established and driveable: ports, listen registry,
    // and staged output all came across, and a host send works immediately.
    try testing.expectEqual(@as(u64, 3), vs2.guest_cid);
    try testing.expect(vs2.isListening(5000));
    try testing.expectEqual(Conn.State.established, vs2.conns[id].state);
    try testing.expectEqual(@as(u32, 5000), vs2.conns[id].host_port);
    try testing.expectEqual(@as(u32, 50), vs2.conns[id].guest_port);
    // The pre-snapshot staged RW packet is still queued (RESPONSE drained, then "ping").
    var hdrs: [4]Hdr = undefined;
    const n = drainHdrs(&vs2, &hdrs);
    try testing.expect(n >= 1);
    try testing.expectEqual(Op.RW, hdrs[n - 1].op);
    // And the connection accepts a fresh host send post-import.
    try testing.expectEqual(@as(usize, 4), vs2.send(id, "pong"));
}

test "accept-window policy bounds guest conns on the configured port only" {
    var vs = Vsock{ .guest_cid = 3 };
    var rec = Recorder{};
    defer rec.deinit();
    vs.on_event = Recorder.sink;
    vs.on_event_ctx = &rec;
    _ = vs.listen(5000);
    _ = vs.listen(5002);
    vs.accept_defer_port = 5002; // the egress plane's policy (hostListenWindow)
    vs.accept_defer_window = 256 * 1024;
    var pbuf: [HDR_LEN]u8 = undefined;
    // A conn to the configured port gets the bounded window + deferred credit...
    vs.rx(guestPkt(&pbuf, .{ .src_cid = 3, .dst_cid = HOST_CID, .src_port = 60, .dst_port = 5002, .op = Op.REQUEST, .buf_alloc = 65536 }, &.{}));
    const eg = vs.findConn(5002, 60).?;
    try testing.expectEqual(@as(u32, 256 * 1024), vs.conns[eg].buf_alloc);
    try testing.expect(vs.conns[eg].defer_credit);
    // ...and the RESPONSE advertised exactly that window to the guest.
    var hdrs: [4]Hdr = undefined;
    const n = drainHdrs(&vs, &hdrs);
    try testing.expect(n >= 1);
    try testing.expectEqual(Op.RESPONSE, hdrs[n - 1].op);
    try testing.expectEqual(@as(u32, 256 * 1024), hdrs[n - 1].buf_alloc);
    // A conn to a DIFFERENT listened port keeps the defaults (auto-credit, big window).
    vs.rx(guestPkt(&pbuf, .{ .src_cid = 3, .dst_cid = HOST_CID, .src_port = 61, .dst_port = 5000, .op = Op.REQUEST, .buf_alloc = 65536 }, &.{}));
    const ag = vs.findConn(5000, 61).?;
    try testing.expectEqual(DEFAULT_BUF_ALLOC, vs.conns[ag].buf_alloc);
    try testing.expect(!vs.conns[ag].defer_credit);
}

test "validState rejects a corrupt staging ring (no OOB on import)" {
    var s = Vsock.State{ .guest_cid = 3 };
    try testing.expect(Vsock.validState(&s)); // a zeroed/empty ring is valid

    var bad = s;
    bad.out_head = OUT_RING; // index would OOB out[] in peekOut
    try testing.expect(!Vsock.validState(&bad));

    bad = s;
    bad.out_tail = OUT_RING + 5; // index would OOB out[] in pushOut
    try testing.expect(!Vsock.validState(&bad));

    bad = s;
    bad.out_count = OUT_RING + 1; // more staged than the ring can hold
    try testing.expect(!Vsock.validState(&bad));

    bad = s;
    bad.out_head = std.math.maxInt(usize); // garbage usize from a bit-flipped file
    try testing.expect(!Vsock.validState(&bad));

    bad = s;
    bad.out[3].len = PKT_CAP + 1; // a len that would slice buf[0..len] out of bounds
    try testing.expect(!Vsock.validState(&bad));

    bad = s;
    bad.out[0].len = PKT_CAP; // exactly the buffer size is fine
    try testing.expect(Vsock.validState(&bad));
}

// --- device-glue tests (full virtqueue path) -------------------------------
//
// Memory layout in the shared `ram` (guest base 0):
//   TX queue: desc 0x0000, avail 0x0200, used 0x0400
//   RX queue: desc 0x0600, avail 0x0800, used 0x0A00
//   TX packet buffer 0x1000; RX buffers 0x2000 and 0x3000 (4 KiB each)

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

test "device: a guest REQUEST kick yields a RESPONSE on the RX ring" {
    var ram = [_]u8{0} ** 16384;
    var vs = Vsock{ .guest_cid = 3 };
    _ = vs.listen(7);
    var vdev = VsockDev{ .engine = &vs };
    var dev = virtio.Device.init(vdev.backend(), .{ .bytes = &ram, .base = 0 });

    // guest_cid is exposed in device config (u64 at offset 0).
    try testing.expectEqual(@as(u32, 3), dev.barRead(0x3000, 4));

    progQueue(&dev, RXQ, 8, RX_DESC, RX_AVAIL, RX_USED);
    progQueue(&dev, TXQ, 8, TX_DESC, TX_AVAIL, TX_USED);

    // RX: one device-writable 4 KiB buffer the host can place a packet in.
    wdesc(&ram, RX_DESC, 0x2000, 0x1000, virtq.DESC_F_WRITE, 0);
    std.mem.writeInt(u16, ram[RX_AVAIL + 4 ..][0..2], 0, .little); // ring[0] = desc 0
    std.mem.writeInt(u16, ram[RX_AVAIL + 2 ..][0..2], 1, .little); // avail.idx = 1

    // TX: a device-readable buffer holding a REQUEST to listened port 7.
    const req = Hdr{ .src_cid = 3, .dst_cid = HOST_CID, .src_port = 50, .dst_port = 7, .op = Op.REQUEST, .buf_alloc = 4096 };
    req.encode(ram[0x1000..][0..HDR_LEN]);
    wdesc(&ram, TX_DESC, 0x1000, HDR_LEN, 0, 0);
    std.mem.writeInt(u16, ram[TX_AVAIL + 4 ..][0..2], 0, .little);
    std.mem.writeInt(u16, ram[TX_AVAIL + 2 ..][0..2], 1, .little);

    dev.barWrite(0x2000, 4, TXQ); // kick the TX queue

    // The connection is established and a RESPONSE landed in the RX buffer.
    try testing.expectEqual(Conn.State.established, vs.conns[0].state);
    try testing.expectEqual(@as(u16, 1), usedIdx(&ram, TX_USED)); // TX buffer reclaimed
    try testing.expectEqual(@as(u16, 1), usedIdx(&ram, RX_USED)); // RX packet delivered
    const resp = Hdr.decode(ram[0x2000..][0..HDR_LEN]).?;
    try testing.expectEqual(Op.RESPONSE, resp.op);
    try testing.expectEqual(@as(u32, 7), resp.src_port);
    try testing.expectEqual(@as(u32, 50), resp.dst_port);
    // The used-ring length is the full packet (header, no payload).
    try testing.expectEqual(@as(u32, HDR_LEN), std.mem.readInt(u32, ram[RX_USED + 8 ..][0..4], .little));
}

test "device: host send is delivered to a posted RX buffer" {
    var ram = [_]u8{0} ** 16384;
    var vs = Vsock{ .guest_cid = 3 };
    _ = vs.listen(7);
    var vdev = VsockDev{ .engine = &vs };
    var dev = virtio.Device.init(vdev.backend(), .{ .bytes = &ram, .base = 0 });
    vdev.attach(&dev);

    progQueue(&dev, RXQ, 8, RX_DESC, RX_AVAIL, RX_USED);
    progQueue(&dev, TXQ, 8, TX_DESC, TX_AVAIL, TX_USED);

    // Two RX buffers up front: the RESPONSE takes the first, host data the next.
    wdesc(&ram, RX_DESC + 0, 0x2000, 0x1000, virtq.DESC_F_WRITE, 0);
    wdesc(&ram, RX_DESC + 16, 0x3000, 0x1000, virtq.DESC_F_WRITE, 0);
    std.mem.writeInt(u16, ram[RX_AVAIL + 4 ..][0..2], 0, .little); // ring[0] = desc 0
    std.mem.writeInt(u16, ram[RX_AVAIL + 6 ..][0..2], 1, .little); // ring[1] = desc 1
    std.mem.writeInt(u16, ram[RX_AVAIL + 2 ..][0..2], 2, .little); // avail.idx = 2

    // Handshake (REQUEST -> RESPONSE) so the connection is established.
    const req = Hdr{ .src_cid = 3, .dst_cid = HOST_CID, .src_port = 50, .dst_port = 7, .op = Op.REQUEST, .buf_alloc = 4096 };
    req.encode(ram[0x1000..][0..HDR_LEN]);
    wdesc(&ram, TX_DESC, 0x1000, HDR_LEN, 0, 0);
    std.mem.writeInt(u16, ram[TX_AVAIL + 4 ..][0..2], 0, .little);
    std.mem.writeInt(u16, ram[TX_AVAIL + 2 ..][0..2], 1, .little);
    dev.barWrite(0x2000, 4, TXQ);
    try testing.expectEqual(@as(u16, 1), usedIdx(&ram, RX_USED)); // RESPONSE used buffer 0

    // Host (swerver) sends data on the established connection (id 0).
    try testing.expectEqual(@as(usize, 4), vdev.hostSend(0, "ping"));
    try testing.expectEqual(@as(u16, 2), usedIdx(&ram, RX_USED)); // delivered to buffer 1

    const data = Hdr.decode(ram[0x3000..][0..HDR_LEN]).?;
    try testing.expectEqual(Op.RW, data.op);
    try testing.expectEqual(@as(u32, 4), data.len);
    try testing.expectEqualStrings("ping", ram[0x3000 + HDR_LEN ..][0..4]);
}
