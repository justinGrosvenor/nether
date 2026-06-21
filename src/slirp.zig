//! User-mode networking ("slirp-lite"): a tiny in-VMM network stack that lets an
//! unprivileged guest have a configured `eth0` with no host tap, bridge, vmnet, or
//! root. It sits behind the virtio-net backend: the guest's transmitted Ethernet
//! frames are handed to `onGuestFrame`, and replies are pushed back to the guest's
//! RX via the `out` sink (wired to `Net.pushRx`).
//!
//! This first cut implements the link/internet basics needed for autoconfig and
//! liveness: ARP (so the guest can resolve the virtual gateway), DHCP (so it gets
//! an address, gateway and DNS without static config), and ICMP echo (so it can
//! ping the gateway). Outbound NAT to real host sockets (UDP/DNS, TCP) builds on
//! this and is the next step. The address plan mirrors QEMU's slirp defaults:
//! guest 10.0.2.15, gateway 10.0.2.2, DNS 10.0.2.3, /24.

const std = @import("std");
const Lock = @import("lock.zig").Lock;

// Host BSD sockets for outbound NAT (no privilege required). Portable libc; the
// NAT path only runs on the macOS/HVF net path, but the bindings compile anywhere.
const sock = struct {
    const AF_INET: c_int = 2;
    const SOCK_STREAM: c_int = 1;
    const SOCK_DGRAM: c_int = 2;
    const F_SETFL: c_int = 4;
    const O_NONBLOCK: c_int = 0x0004; // macOS
    const POLLIN: c_short = 0x0001;
    const POLLOUT: c_short = 0x0004;
    const SOL_SOCKET: c_int = 0xffff; // macOS
    const SO_ERROR: c_int = 0x1007; // macOS
    const SHUT_WR: c_int = 1;

    // macOS sockaddr_in (note the leading sin_len byte).
    const sockaddr_in = extern struct {
        len: u8 = 16,
        family: u8 = AF_INET,
        port: u16 = 0, // network byte order
        addr: u32 = 0, // network byte order
        zero: [8]u8 = .{0} ** 8,
    };
    const pollfd = extern struct { fd: c_int, events: c_short, revents: c_short = 0 };

    extern "c" fn socket(domain: c_int, ty: c_int, proto: c_int) c_int;
    extern "c" fn connect(fd: c_int, addr: *const sockaddr_in, len: u32) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn send(fd: c_int, buf: [*]const u8, n: usize, flags: c_int) isize;
    extern "c" fn recv(fd: c_int, buf: [*]u8, n: usize, flags: c_int) isize;
    extern "c" fn fcntl(fd: c_int, cmd: c_int, arg: c_int) c_int;
    extern "c" fn poll(fds: [*]pollfd, n: c_uint, timeout: c_int) c_int;
    extern "c" fn getsockopt(fd: c_int, level: c_int, opt: c_int, val: *c_int, len: *u32) c_int;
    extern "c" fn shutdown(fd: c_int, how: c_int) c_int;
};

// macOS timeval: tv_sec is time_t (i64), tv_usec is suseconds_t (i32).
const timeval = extern struct { sec: i64, usec: i32 };
extern "c" fn gettimeofday(tv: *timeval, tz: ?*anyopaque) c_int;
fn nowMs() u64 {
    var tv: timeval = .{ .sec = 0, .usec = 0 };
    _ = gettimeofday(&tv, null);
    return @intCast(tv.sec * 1000 + @divTrunc(tv.usec, 1000));
}
// Idle reap thresholds (ms): stale NAT entries are freed so a long-running
// sandbox can't exhaust the fixed tables with abandoned/half-open connections.
const REAP_CONNECTING_MS: u64 = 10_000; // host connect never completed
const REAP_CLOSING_MS: u64 = 10_000; // FIN sent, peer never finished the close
const REAP_ESTABLISHED_MS: u64 = 300_000; // idle established conn (5 min)
const REAP_UDP_MS: u64 = 60_000; // idle UDP flow (1 min)

const ETH_HDR = 14;
const ETHERTYPE_ARP = 0x0806;
const ETHERTYPE_IPV4 = 0x0800;
const IPPROTO_ICMP = 1;
const IPPROTO_TCP = 6;
const IPPROTO_UDP = 17;

// TCP flags.
const TH_FIN: u8 = 0x01;
const TH_SYN: u8 = 0x02;
const TH_RST: u8 = 0x04;
const TH_PSH: u8 = 0x08;
const TH_ACK: u8 = 0x10;

const MAX_TCP = 32;
const TcpState = enum { free, connecting, established, closing };
const TcpConn = struct {
    state: TcpState = .free,
    fd: c_int = -1,
    guest_port: u16 = 0,
    dst_ip: [4]u8 = .{ 0, 0, 0, 0 },
    dst_port: u16 = 0,
    snd_nxt: u32 = 0, // next seq we will send to the guest
    snd_una: u32 = 0, // earliest seq the guest has not yet ACKed
    rcv_nxt: u32 = 0, // next seq we expect from the guest
    guest_win: u32 = 0, // the guest's advertised receive window (unscaled)
    guest_mss: u16 = 1460,
    guest_fin: bool = false,
    fin_sent: bool = false,
    last_ms: u64 = 0, // last activity, for the idle reaper
};

const MAX_UDP = 32;
const UdpFlow = struct {
    used: bool = false,
    fd: c_int = -1,
    guest_port: u16 = 0, // the response is sent back to this guest port
    /// The address/port the guest believes it is talking to (the response's src,
    /// so the guest accepts it). For DNS this is dns_ip:53 even though the real
    /// socket talks to upstream_dns.
    seen_ip: [4]u8 = .{ 0, 0, 0, 0 },
    seen_port: u16 = 0,
    last_ms: u64 = 0, // last activity, for the idle reaper
};

pub const Slirp = struct {
    guest_ip: [4]u8 = .{ 10, 0, 2, 15 },
    gateway_ip: [4]u8 = .{ 10, 0, 2, 2 },
    dns_ip: [4]u8 = .{ 10, 0, 2, 3 },
    mask: [4]u8 = .{ 255, 255, 255, 0 },
    /// The virtual gateway's MAC (locally administered). The guest's MAC matches
    /// virtio_net.zig's default.
    gateway_mac: [6]u8 = .{ 0x52, 0x54, 0x00, 0x12, 0x35, 0x02 },
    guest_mac: [6]u8 = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 },

    /// Upstream DNS the guest's queries (to dns_ip:53) are forwarded to.
    upstream_dns: [4]u8 = .{ 8, 8, 8, 8 },

    /// Sink for frames we send to the guest (wired to Net.pushRx).
    out_fn: ?*const fn (ctx: *anyopaque, frame: []const u8) void = null,
    out_ctx: ?*anyopaque = null,

    scratch: [2048]u8 = undefined,

    // Outbound UDP NAT: each guest UDP flow maps to a host UDP socket. The poll
    // loop (host thread) reads replies and injects them back to the guest, so the
    // table is shared with the vCPU thread and guarded by `lock`.
    udp: [MAX_UDP]UdpFlow = [_]UdpFlow{.{}} ** MAX_UDP,
    tcp: [MAX_TCP]TcpConn = [_]TcpConn{.{}} ** MAX_TCP,
    isn_ctr: u32 = 0x1000_0000, // our TCP initial-sequence-number generator
    lock: Lock = .{},
    poll_scratch: [2048]u8 = undefined, // reply assembly on the poll thread

    // Network egress metering: payload bytes that traverse the NAT to/from the
    // real internet (a host-measurable billing dimension, unlike guest compute).
    tx_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0), // guest -> internet
    rx_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0), // internet -> guest

    /// Entry point: a raw Ethernet frame the guest transmitted.
    pub fn onGuestFrame(self: *Slirp, frame: []const u8) void {
        if (frame.len < ETH_HDR) return;
        switch (rd16(frame[12..14])) {
            ETHERTYPE_ARP => self.handleArp(frame),
            ETHERTYPE_IPV4 => self.handleIpv4(frame),
            else => {},
        }
    }

    fn send(self: *Slirp, frame: []const u8) void {
        if (self.out_fn) |f| f(self.out_ctx.?, frame);
    }

    // --- ARP ---------------------------------------------------------------
    fn handleArp(self: *Slirp, frame: []const u8) void {
        const a = frame[ETH_HDR..];
        if (a.len < 28) return;
        if (rd16(a[6..8]) != 1) return; // opcode: request
        const target_ip = a[24..28]; // TPA
        // Answer for the gateway and the DNS address (both are "us").
        if (!eqIp(target_ip, &self.gateway_ip) and !eqIp(target_ip, &self.dns_ip)) return;

        var buf = self.scratch[0 .. ETH_HDR + 28];
        // Ethernet: to the requester, from the gateway.
        @memcpy(buf[0..6], frame[6..12]);
        @memcpy(buf[6..12], &self.gateway_mac);
        wr16(buf[12..14], ETHERTYPE_ARP);
        const r = buf[ETH_HDR..];
        wr16(r[0..2], 1); // htype ethernet
        wr16(r[2..4], ETHERTYPE_IPV4); // ptype
        r[4] = 6; // hlen
        r[5] = 4; // plen
        wr16(r[6..8], 2); // opcode: reply
        @memcpy(r[8..14], &self.gateway_mac); // SHA
        @memcpy(r[14..18], target_ip); // SPA = the address asked for
        @memcpy(r[18..24], a[8..14]); // THA = requester MAC
        @memcpy(r[24..28], a[14..18]); // TPA = requester IP
        self.send(buf);
    }

    // --- IPv4 --------------------------------------------------------------
    fn handleIpv4(self: *Slirp, frame: []const u8) void {
        const ip = frame[ETH_HDR..];
        if (ip.len < 20) return;
        const ihl = (ip[0] & 0x0f) * 4;
        if (ihl < 20 or ip.len < ihl) return;
        switch (ip[9]) {
            IPPROTO_ICMP => self.handleIcmp(frame, ihl),
            IPPROTO_UDP => self.handleUdp(frame, ihl),
            IPPROTO_TCP => self.tcpOut(ip, ihl),
            else => {},
        }
    }

    fn handleIcmp(self: *Slirp, frame: []const u8, ihl: usize) void {
        const ip = frame[ETH_HDR..];
        const icmp = ip[ihl..];
        if (icmp.len < 8 or icmp[0] != 8) return; // echo request only
        // Only answer pings to the gateway (we are the gateway).
        if (!eqIp(ip[16..20], &self.gateway_ip)) return;

        const total = ETH_HDR + ihl + icmp.len;
        if (total > self.scratch.len) return;
        var buf = self.scratch[0..total];
        ethReply(buf, frame, &self.gateway_mac, ETHERTYPE_IPV4);
        // IP header: swap src/dst, copy the rest, recompute checksum.
        const oip = buf[ETH_HDR..];
        @memcpy(oip[0..ihl], ip[0..ihl]);
        @memcpy(oip[12..16], ip[16..20]); // src = original dst (gateway)
        @memcpy(oip[16..20], ip[12..16]); // dst = original src (guest)
        // ICMP echo reply: type 0, copy id/seq/payload, recompute checksum.
        const oicmp = oip[ihl..];
        @memcpy(oicmp, icmp);
        oicmp[0] = 0; // echo reply
        wr16(oicmp[2..4], 0);
        wr16(oicmp[2..4], checksum(oicmp));
        wr16(oip[10..12], 0);
        wr16(oip[10..12], checksum(oip[0..ihl]));
        self.send(buf);
    }

    fn handleUdp(self: *Slirp, frame: []const u8, ihl: usize) void {
        const ip = frame[ETH_HDR..];
        const udp = ip[ihl..];
        if (udp.len < 8) return;
        const dport = rd16(udp[2..4]);
        if (dport == 67) {
            self.handleDhcp(frame, ihl); // BOOTP/DHCP server port
        } else {
            self.udpOut(ip, ihl); // outbound UDP NAT (incl. DNS to dns_ip:53)
        }
    }

    // --- outbound UDP NAT --------------------------------------------------
    fn udpOut(self: *Slirp, ip: []const u8, ihl: usize) void {
        const udp = ip[ihl..];
        const sport = rd16(udp[0..2]);
        const dport = rd16(udp[2..4]);
        const payload = udp[8..@min(udp.len, 8 + (rd16(udp[4..6]) -| 8))];
        var dst_ip: [4]u8 = ip[16..20][0..4].*;
        // A query to our virtual DNS address is forwarded to the real upstream.
        const is_dns = eqIp(&dst_ip, &self.dns_ip) and dport == 53;
        const real_ip = if (is_dns) self.upstream_dns else dst_ip;

        self.lock.lock();
        defer self.lock.unlock();
        const flow = self.udpFlow(sport, &dst_ip, dport) orelse return;
        flow.last_ms = nowMs();
        if (flow.fd < 0) {
            const fd = sock.socket(sock.AF_INET, sock.SOCK_DGRAM, 0);
            if (fd < 0) return;
            _ = sock.fcntl(fd, sock.F_SETFL, sock.O_NONBLOCK);
            var sa = sock.sockaddr_in{ .port = std.mem.nativeToBig(u16, dport), .addr = ipToBe(&real_ip) };
            if (sock.connect(fd, &sa, 16) < 0) {
                _ = sock.close(fd);
                return;
            }
            flow.fd = fd;
        }
        _ = sock.send(flow.fd, payload.ptr, payload.len, 0);
        _ = self.tx_bytes.fetchAdd(payload.len, .monotonic);
    }

    /// Find (or allocate) the UDP flow for this guest source port + destination.
    fn udpFlow(self: *Slirp, sport: u16, dst_ip: *const [4]u8, dport: u16) ?*UdpFlow {
        var free: ?*UdpFlow = null;
        for (&self.udp) |*f| {
            if (f.used and f.guest_port == sport and f.seen_port == dport and eqIp(&f.seen_ip, dst_ip)) return f;
            if (!f.used and free == null) free = f;
        }
        const f = free orelse return null;
        f.* = .{ .used = true, .fd = -1, .guest_port = sport, .seen_ip = dst_ip.*, .seen_port = dport };
        return f;
    }

    /// Host thread: poll all NAT sockets (UDP flows + TCP conns) and move data
    /// between them and the guest. Returns after one poll cycle (caller loops).
    /// Free NAT entries idle past their reap threshold so a long-running sandbox
    /// can't exhaust the fixed tables with abandoned/half-open connections.
    /// Caller holds the lock.
    fn reapStale(self: *Slirp, now: u64) void {
        for (&self.tcp) |*c| {
            const limit: u64 = switch (c.state) {
                .free => continue,
                .connecting => REAP_CONNECTING_MS,
                .closing => REAP_CLOSING_MS,
                .established => REAP_ESTABLISHED_MS,
            };
            if (now -% c.last_ms > limit) self.tcpClose(c);
        }
        for (&self.udp) |*f| {
            if (f.used and now -% f.last_ms > REAP_UDP_MS) {
                if (f.fd >= 0) _ = sock.close(f.fd);
                f.* = .{};
            }
        }
    }

    pub fn pollOnce(self: *Slirp, timeout_ms: i32) void {
        const N = MAX_UDP + MAX_TCP;
        var fds: [N]sock.pollfd = undefined;
        var tag: [N]u32 = undefined; // bit 31 = TCP; low bits = table index
        var n: u32 = 0;
        self.lock.lock();
        self.reapStale(nowMs());
        for (&self.udp, 0..) |*f, i| {
            if (f.used and f.fd >= 0) {
                fds[n] = .{ .fd = f.fd, .events = sock.POLLIN };
                tag[n] = @intCast(i);
                n += 1;
            }
        }
        for (&self.tcp, 0..) |*c, i| {
            const ev: sock.pollfd = switch (c.state) {
                .connecting => .{ .fd = c.fd, .events = sock.POLLOUT },
                .established => blk: {
                    // Only read from the host while the guest's window has room,
                    // so a full window does not spin the poll loop.
                    if (c.guest_win > (c.snd_nxt -% c.snd_una)) break :blk .{ .fd = c.fd, .events = sock.POLLIN };
                    continue;
                },
                else => continue,
            };
            fds[n] = ev;
            tag[n] = 0x8000_0000 | @as(u32, @intCast(i));
            n += 1;
        }
        self.lock.unlock();
        if (n == 0) {
            _ = sock.poll(&fds, 0, timeout_ms);
            return;
        }
        if (sock.poll(&fds, n, timeout_ms) <= 0) return;
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            if (fds[k].revents == 0) continue;
            if (tag[k] & 0x8000_0000 != 0) self.tcpPollReady(tag[k] & 0x7fff_ffff, fds[k].revents) else self.udpPollReady(tag[k], fds[k].revents);
        }
    }

    fn udpPollReady(self: *Slirp, i: u32, revents: c_short) void {
        if (revents & sock.POLLIN == 0) return;
        self.lock.lock();
        const f = &self.udp[i];
        const got = if (f.used and f.fd >= 0) sock.recv(f.fd, self.poll_scratch[0..1500].ptr, 1500, 0) else -1;
        if (got > 0) f.last_ms = nowMs();
        const sip = f.seen_ip;
        const sport = f.seen_port;
        const gport = f.guest_port;
        self.lock.unlock();
        if (got <= 0) return;
        _ = self.rx_bytes.fetchAdd(@intCast(got), .monotonic);
        self.injectUdpToGuest(&sip, sport, gport, self.poll_scratch[0..@intCast(got)]);
    }

    fn tcpPollReady(self: *Slirp, i: u32, revents: c_short) void {
        self.lock.lock();
        defer self.lock.unlock();
        const c = &self.tcp[i];
        c.last_ms = nowMs();
        if (c.state == .connecting) {
            var err: c_int = 0;
            var len: u32 = 4;
            _ = sock.getsockopt(c.fd, sock.SOL_SOCKET, sock.SO_ERROR, &err, &len);
            if (err != 0) { // connect failed -> reset the guest
                self.tcpSend(c, c.snd_nxt, TH_RST | TH_ACK, &.{}, null);
                self.tcpClose(c);
                return;
            }
            c.state = .established;
            self.tcpSend(c, c.snd_nxt, TH_SYN | TH_ACK, &.{}, c.guest_mss);
            c.snd_nxt +%= 1; // the SYN consumes a sequence number
            return;
        }
        if (c.state == .established and revents & sock.POLLIN != 0) {
            const inflight = c.snd_nxt -% c.snd_una;
            if (c.guest_win <= inflight) return;
            var room: u32 = c.guest_win - inflight;
            if (room > c.guest_mss) room = c.guest_mss;
            if (room > 1400) room = 1400;
            const got = sock.recv(c.fd, self.poll_scratch[0..room].ptr, room, 0);
            if (got > 0) {
                self.tcpSend(c, c.snd_nxt, TH_PSH | TH_ACK, self.poll_scratch[0..@intCast(got)], null);
                c.snd_nxt +%= @intCast(got);
                _ = self.rx_bytes.fetchAdd(@intCast(got), .monotonic);
            } else if (got == 0) { // host EOF -> FIN to the guest
                self.tcpSend(c, c.snd_nxt, TH_FIN | TH_ACK, &.{}, null);
                c.snd_nxt +%= 1;
                c.fin_sent = true;
                c.state = .closing;
            }
        }
    }

    // --- outbound TCP NAT --------------------------------------------------
    // The guest's connection terminates here; we bridge it to a host SOCK_STREAM.
    // The in-process path to the guest is lossless, so no retransmit/congestion
    // logic is needed - only seq/ack bookkeeping and the guest's receive window.
    fn tcpOut(self: *Slirp, ip: []const u8, ihl: usize) void {
        const tcp = ip[ihl..];
        if (tcp.len < 20) return;
        const sport = rd16(tcp[0..2]);
        const dport = rd16(tcp[2..4]);
        const seq = rd32(tcp[4..8]);
        const ack = rd32(tcp[8..12]);
        const doff = (tcp[12] >> 4) * 4;
        if (doff < 20 or tcp.len < doff) return;
        const flags = tcp[13];
        const win: u32 = rd16(tcp[14..16]);
        const payload = tcp[doff..];
        var dst_ip: [4]u8 = ip[16..20][0..4].*;

        self.lock.lock();
        defer self.lock.unlock();
        const conn = self.tcpFind(sport, &dst_ip, dport);

        if (flags & TH_RST != 0) {
            if (conn) |c| self.tcpClose(c);
            return;
        }
        if (conn == null) {
            if (flags & TH_SYN == 0) return; // unknown, not a SYN
            _ = self.tcpOpen(sport, &dst_ip, dport, seq, win, tcp[20..doff]);
            return; // SYN-ACK is sent from the poll loop once the host connect completes
        }
        const c = conn.?;
        c.last_ms = nowMs();
        if (flags & TH_ACK != 0 and seqGt(ack, c.snd_una)) c.snd_una = ack;
        c.guest_win = win;

        if (payload.len > 0 and c.state == .established and seq == c.rcv_nxt) {
            const n = sock.send(c.fd, payload.ptr, payload.len, 0);
            if (n > 0) {
                c.rcv_nxt +%= @intCast(n);
                _ = self.tx_bytes.fetchAdd(@intCast(n), .monotonic);
            }
        }
        if (payload.len > 0 and c.state == .established) self.tcpSend(c, c.snd_nxt, TH_ACK, &.{}, null);

        if (flags & TH_FIN != 0 and seq == c.rcv_nxt and !c.guest_fin) {
            c.guest_fin = true;
            c.rcv_nxt +%= 1;
            _ = sock.shutdown(c.fd, sock.SHUT_WR); // host sees EOF
            self.tcpSend(c, c.snd_nxt, TH_ACK, &.{}, null);
            if (c.fin_sent) self.tcpClose(c);
        }
    }

    fn tcpFind(self: *Slirp, sport: u16, dst_ip: *const [4]u8, dport: u16) ?*TcpConn {
        for (&self.tcp) |*c| {
            if (c.state != .free and c.guest_port == sport and c.dst_port == dport and eqIp(&c.dst_ip, dst_ip)) return c;
        }
        return null;
    }

    fn tcpOpen(self: *Slirp, sport: u16, dst_ip: *const [4]u8, dport: u16, guest_isn: u32, win: u32, opts: []const u8) ?*TcpConn {
        var slot: ?*TcpConn = null;
        for (&self.tcp) |*c| {
            if (c.state == .free) {
                slot = c;
                break;
            }
        }
        const c = slot orelse return null;
        const fd = sock.socket(sock.AF_INET, sock.SOCK_STREAM, 0);
        if (fd < 0) return null;
        _ = sock.fcntl(fd, sock.F_SETFL, sock.O_NONBLOCK);
        var sa = sock.sockaddr_in{ .port = std.mem.nativeToBig(u16, dport), .addr = ipToBe(dst_ip) };
        _ = sock.connect(fd, &sa, 16); // EINPROGRESS expected; the poll loop finishes it
        self.isn_ctr +%= 0x1_0000;
        c.* = .{
            .state = .connecting,
            .fd = fd,
            .guest_port = sport,
            .dst_ip = dst_ip.*,
            .dst_port = dport,
            .snd_nxt = self.isn_ctr,
            .snd_una = self.isn_ctr,
            .rcv_nxt = guest_isn +% 1,
            .guest_win = win,
            .guest_mss = parseMss(opts),
            .last_ms = nowMs(),
        };
        return c;
    }

    fn tcpClose(self: *Slirp, c: *TcpConn) void {
        _ = self;
        if (c.fd >= 0) _ = sock.close(c.fd);
        c.* = .{};
    }

    /// Build and send one TCP segment to the guest with the given seq/flags/data.
    /// `mss` non-null adds an MSS option (for the SYN-ACK). Does not advance seq.
    fn tcpSend(self: *Slirp, c: *TcpConn, seq: u32, flags: u8, payload: []const u8, mss: ?u16) void {
        var buf: [2048]u8 = undefined;
        const opt_len: usize = if (mss != null) 4 else 0;
        const thl = 20 + opt_len;
        const total = ETH_HDR + 20 + thl + payload.len;
        if (total > buf.len) return;
        @memcpy(buf[0..6], &self.guest_mac);
        @memcpy(buf[6..12], &self.gateway_mac);
        wr16(buf[12..14], ETHERTYPE_IPV4);
        const ip = buf[ETH_HDR..];
        ip[0] = 0x45;
        ip[1] = 0;
        wr16(ip[2..4], @intCast(20 + thl + payload.len));
        wr16(ip[4..6], 0);
        wr16(ip[6..8], 0);
        ip[8] = 64;
        ip[9] = IPPROTO_TCP;
        wr16(ip[10..12], 0);
        @memcpy(ip[12..16], &c.dst_ip); // src = the remote the guest dialed
        @memcpy(ip[16..20], &self.guest_ip);
        wr16(ip[10..12], checksum(ip[0..20]));
        const t = ip[20..];
        @memset(t[0..thl], 0);
        wr16(t[0..2], c.dst_port);
        wr16(t[2..4], c.guest_port);
        wr32(t[4..8], seq);
        wr32(t[8..12], c.rcv_nxt);
        t[12] = @intCast((thl / 4) << 4);
        t[13] = flags;
        wr16(t[14..16], 0xffff); // our receive window (no scaling)
        if (mss) |m| {
            t[20] = 2;
            t[21] = 4;
            wr16(t[22..24], m);
        }
        @memcpy(t[thl..][0..payload.len], payload);
        wr16(t[16..18], tcpChecksum(&c.dst_ip, &self.guest_ip, t[0 .. thl + payload.len]));
        self.send(buf[0..total]);
    }

    /// Build Ethernet+IPv4+UDP from (src_ip:sport) to the guest:gport and send it.
    fn injectUdpToGuest(self: *Slirp, src_ip: *const [4]u8, sport: u16, gport: u16, payload: []const u8) void {
        const total = ETH_HDR + 20 + 8 + payload.len;
        if (total > self.poll_scratch.len) return;
        // Assemble in a local buffer (poll_scratch holds the payload).
        var buf: [2048]u8 = undefined;
        @memcpy(buf[0..6], &self.guest_mac);
        @memcpy(buf[6..12], &self.gateway_mac);
        wr16(buf[12..14], ETHERTYPE_IPV4);
        const ip = buf[ETH_HDR..];
        ip[0] = 0x45;
        ip[1] = 0;
        wr16(ip[2..4], @intCast(20 + 8 + payload.len));
        wr16(ip[4..6], 0);
        wr16(ip[6..8], 0);
        ip[8] = 64;
        ip[9] = IPPROTO_UDP;
        wr16(ip[10..12], 0);
        @memcpy(ip[12..16], src_ip);
        @memcpy(ip[16..20], &self.guest_ip);
        wr16(ip[10..12], checksum(ip[0..20]));
        const udp = ip[20..];
        wr16(udp[0..2], sport);
        wr16(udp[2..4], gport);
        wr16(udp[4..6], @intCast(8 + payload.len));
        wr16(udp[6..8], 0);
        @memcpy(udp[8..][0..payload.len], payload);
        self.send(buf[0..total]);
    }

    // --- DHCP --------------------------------------------------------------
    fn handleDhcp(self: *Slirp, frame: []const u8, ihl: usize) void {
        const ip = frame[ETH_HDR..];
        const udp = ip[ihl..];
        const bootp = udp[8..];
        if (bootp.len < 240) return; // BOOTP fixed area + magic cookie
        if (rd32(bootp[236..240]) != 0x6382_5363) return; // DHCP magic cookie

        // Find option 53 (message type) in the options area.
        var req_type: u8 = 0;
        var i: usize = 240;
        while (i + 1 < bootp.len) {
            const opt = bootp[i];
            if (opt == 255) break; // end
            if (opt == 0) {
                i += 1;
                continue;
            } // pad
            const len = bootp[i + 1];
            if (opt == 53 and len >= 1) req_type = bootp[i + 2];
            i += 2 + len;
        }
        const reply_type: u8 = switch (req_type) {
            1 => 2, // DISCOVER -> OFFER
            3 => 5, // REQUEST  -> ACK
            else => return,
        };
        self.sendDhcpReply(frame, bootp, reply_type);
    }

    fn sendDhcpReply(self: *Slirp, frame: []const u8, req_bootp: []const u8, msg_type: u8) void {
        // Build BOOTP reply into a temp, then wrap in UDP/IP/Ethernet.
        var bp = [_]u8{0} ** 300;
        bp[0] = 2; // op: reply
        bp[1] = 1; // htype ethernet
        bp[2] = 6; // hlen
        @memcpy(bp[4..8], req_bootp[4..8]); // xid
        @memcpy(bp[16..20], &self.guest_ip); // yiaddr (offered)
        @memcpy(bp[20..24], &self.gateway_ip); // siaddr (next server / us)
        @memcpy(bp[28..34], req_bootp[28..34]); // chaddr = client MAC
        wr32(bp[236..240], 0x6382_5363); // magic cookie
        var o: usize = 240;
        // 53 message type
        bp[o] = 53;
        bp[o + 1] = 1;
        bp[o + 2] = msg_type;
        o += 3;
        // 54 server identifier
        bp[o] = 54;
        bp[o + 1] = 4;
        @memcpy(bp[o + 2 .. o + 6], &self.gateway_ip);
        o += 6;
        // 51 lease time (1 day)
        bp[o] = 51;
        bp[o + 1] = 4;
        wr32(bp[o + 2 .. o + 6][0..4], 86400);
        o += 6;
        // 1 subnet mask
        bp[o] = 1;
        bp[o + 1] = 4;
        @memcpy(bp[o + 2 .. o + 6], &self.mask);
        o += 6;
        // 3 router
        bp[o] = 3;
        bp[o + 1] = 4;
        @memcpy(bp[o + 2 .. o + 6], &self.gateway_ip);
        o += 6;
        // 6 DNS
        bp[o] = 6;
        bp[o + 1] = 4;
        @memcpy(bp[o + 2 .. o + 6], &self.dns_ip);
        o += 6;
        bp[o] = 255; // end
        o += 1;

        self.sendUdp(frame, &self.gateway_ip, 67, 68, bp[0..o], true);
    }

    /// Build Ethernet+IPv4+UDP around `payload` and send it. `bcast` => broadcast
    /// L2/L3 destination (used for DHCP, which the client may not yet have a lease
    /// to receive unicast).
    fn sendUdp(self: *Slirp, req_frame: []const u8, src_ip: *const [4]u8, sport: u16, dport: u16, payload: []const u8, bcast: bool) void {
        const total = ETH_HDR + 20 + 8 + payload.len;
        if (total > self.scratch.len) return;
        var buf = self.scratch[0..total];
        // Ethernet
        if (bcast) {
            @memset(buf[0..6], 0xff);
        } else {
            @memcpy(buf[0..6], req_frame[6..12]);
        }
        @memcpy(buf[6..12], &self.gateway_mac);
        wr16(buf[12..14], ETHERTYPE_IPV4);
        // IPv4
        const ip = buf[ETH_HDR..];
        ip[0] = 0x45; // v4, ihl 5
        ip[1] = 0;
        wr16(ip[2..4], @intCast(20 + 8 + payload.len));
        wr16(ip[4..6], 0);
        wr16(ip[6..8], 0);
        ip[8] = 64; // TTL
        ip[9] = IPPROTO_UDP;
        wr16(ip[10..12], 0);
        @memcpy(ip[12..16], src_ip);
        if (bcast) @memset(ip[16..20], 0xff) else @memcpy(ip[16..20], &self.guest_ip);
        wr16(ip[10..12], checksum(ip[0..20]));
        // UDP (checksum optional for IPv4; left zero)
        const udp = ip[20..];
        wr16(udp[0..2], sport);
        wr16(udp[2..4], dport);
        wr16(udp[4..6], @intCast(8 + payload.len));
        wr16(udp[6..8], 0);
        @memcpy(udp[8..][0..payload.len], payload);
        self.send(buf);
    }
};

// --- helpers ---------------------------------------------------------------

fn rd16(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .big);
}
fn rd32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}
fn wr16(b: []u8, v: u16) void {
    std.mem.writeInt(u16, b[0..2], v, .big);
}
fn wr32(b: []u8, v: u32) void {
    std.mem.writeInt(u32, b[0..4], v, .big);
}
fn eqIp(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a[0..4], b[0..4]);
}
/// IPv4 octets -> the u32 an in_addr expects (network byte order = the bytes in
/// order, which is exactly the array's memory layout).
fn ipToBe(ip: *const [4]u8) u32 {
    return @bitCast(ip.*);
}
/// Serial-number greater-than (RFC 1982), for TCP sequence/ack comparisons.
fn seqGt(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) > 0;
}
/// Scan TCP options for the MSS (kind 2); default 1460.
fn parseMss(opts: []const u8) u16 {
    var i: usize = 0;
    while (i + 1 < opts.len) {
        const kind = opts[i];
        if (kind == 0) break; // end of options
        if (kind == 1) {
            i += 1;
            continue;
        } // nop
        const len = opts[i + 1];
        if (len < 2) break;
        if (kind == 2 and len == 4 and i + 4 <= opts.len) return rd16(opts[i + 2 ..][0..2]);
        i += len;
    }
    return 1460;
}
/// TCP checksum over the IPv4 pseudo-header + segment.
fn tcpChecksum(src: *const [4]u8, dst: *const [4]u8, seg: []const u8) u16 {
    var sum: u32 = 0;
    sum += rd16(src[0..2]);
    sum += rd16(src[2..4]);
    sum += rd16(dst[0..2]);
    sum += rd16(dst[2..4]);
    sum += IPPROTO_TCP;
    sum += @intCast(seg.len);
    var i: usize = 0;
    while (i + 1 < seg.len) : (i += 2) sum += rd16(seg[i..][0..2]);
    if (i < seg.len) sum += @as(u32, seg[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}

fn ethReply(out: []u8, req_frame: []const u8, src_mac: *const [6]u8, ethertype: u16) void {
    @memcpy(out[0..6], req_frame[6..12]); // to the sender
    @memcpy(out[6..12], src_mac); // from us
    wr16(out[12..14], ethertype);
}

/// One's-complement Internet checksum (RFC 1071).
fn checksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) sum += rd16(data[i..][0..2]);
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

const Sink = struct {
    buf: [2048]u8 = undefined,
    len: usize = 0,
    fn put(ctx: *anyopaque, frame: []const u8) void {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        @memcpy(self.buf[0..frame.len], frame);
        self.len = frame.len;
    }
};

fn ethFrame(buf: []u8, dst: [6]u8, src: [6]u8, ethertype: u16) void {
    @memcpy(buf[0..6], &dst);
    @memcpy(buf[6..12], &src);
    wr16(buf[12..14], ethertype);
}

test "ARP request for the gateway gets a reply with the gateway MAC" {
    var sink = Sink{};
    var s = Slirp{ .out_fn = Sink.put, .out_ctx = &sink };
    var f = [_]u8{0} ** (ETH_HDR + 28);
    ethFrame(&f, .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, s.guest_mac, ETHERTYPE_ARP);
    const a = f[ETH_HDR..];
    wr16(a[0..2], 1); // htype
    wr16(a[2..4], ETHERTYPE_IPV4);
    a[4] = 6;
    a[5] = 4;
    wr16(a[6..8], 1); // request
    @memcpy(a[8..14], &s.guest_mac); // SHA
    @memcpy(a[14..18], &s.guest_ip); // SPA
    @memcpy(a[24..28], &s.gateway_ip); // TPA = gateway
    s.onGuestFrame(&f);

    try testing.expect(sink.len > 0);
    const r = sink.buf[ETH_HDR..sink.len];
    try testing.expectEqual(@as(u16, 2), rd16(r[6..8])); // opcode reply
    try testing.expectEqualSlices(u8, &s.gateway_mac, r[8..14]); // SHA = gateway
    try testing.expectEqualSlices(u8, &s.guest_mac, sink.buf[0..6]); // dst = requester
}

test "DHCP DISCOVER yields an OFFER with the guest address and options" {
    var sink = Sink{};
    var s = Slirp{ .out_fn = Sink.put, .out_ctx = &sink };
    var f = [_]u8{0} ** (ETH_HDR + 20 + 8 + 244);
    ethFrame(&f, .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, s.guest_mac, ETHERTYPE_IPV4);
    const ip = f[ETH_HDR..];
    ip[0] = 0x45;
    ip[9] = IPPROTO_UDP;
    const udp = ip[20..];
    wr16(udp[2..4], 67); // dst port = DHCP server
    const bootp = udp[8..];
    bootp[0] = 1; // request
    @memcpy(bootp[28..34], &s.guest_mac);
    wr32(bootp[236..240], 0x6382_5363);
    bootp[240] = 53;
    bootp[241] = 1;
    bootp[242] = 1; // DISCOVER
    bootp[243] = 255;
    s.onGuestFrame(&f);

    try testing.expect(sink.len > 0);
    const oip = sink.buf[ETH_HDR..];
    try testing.expectEqual(IPPROTO_UDP, oip[9]);
    const obootp = oip[20 + 8 ..];
    try testing.expectEqual(@as(u8, 2), obootp[0]); // reply
    try testing.expectEqualSlices(u8, &s.guest_ip, obootp[16..20]); // yiaddr
    try testing.expectEqual(@as(u8, 53), obootp[240]);
    try testing.expectEqual(@as(u8, 2), obootp[242]); // OFFER
}

test "reaper frees stale NAT entries and keeps fresh ones" {
    var s = Slirp{};
    s.tcp[0] = .{ .state = .closing, .fd = -1, .last_ms = 0 }; // idle past threshold
    s.tcp[1] = .{ .state = .established, .fd = -1, .last_ms = 1_000_000 }; // fresh
    s.udp[0] = .{ .used = true, .fd = -1, .last_ms = 0 }; // stale flow
    s.reapStale(1_000_001);
    try testing.expectEqual(TcpState.free, s.tcp[0].state); // closing reaped
    try testing.expectEqual(TcpState.established, s.tcp[1].state); // fresh kept
    try testing.expect(!s.udp[0].used); // stale udp reaped
}

test "ICMP echo to the gateway is answered" {
    var sink = Sink{};
    var s = Slirp{ .out_fn = Sink.put, .out_ctx = &sink };
    var f = [_]u8{0} ** (ETH_HDR + 20 + 8 + 4);
    ethFrame(&f, s.gateway_mac, s.guest_mac, ETHERTYPE_IPV4);
    const ip = f[ETH_HDR..];
    ip[0] = 0x45;
    ip[9] = IPPROTO_ICMP;
    @memcpy(ip[12..16], &s.guest_ip);
    @memcpy(ip[16..20], &s.gateway_ip);
    const icmp = ip[20..];
    icmp[0] = 8; // echo request
    wr16(icmp[4..6], 0x1234); // id
    wr16(icmp[6..8], 1); // seq
    s.onGuestFrame(&f);

    try testing.expect(sink.len > 0);
    const oip = sink.buf[ETH_HDR..sink.len];
    try testing.expectEqual(IPPROTO_ICMP, oip[9]);
    try testing.expectEqualSlices(u8, &s.gateway_ip, oip[12..16]); // from gateway
    try testing.expectEqualSlices(u8, &s.guest_ip, oip[16..20]); // to guest
    try testing.expectEqual(@as(u8, 0), oip[20]); // echo reply
    try testing.expectEqual(@as(u16, 0), checksum(oip[20..])); // valid ICMP checksum
}
