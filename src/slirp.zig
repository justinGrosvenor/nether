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

const ETH_HDR = 14;
const ETHERTYPE_ARP = 0x0806;
const ETHERTYPE_IPV4 = 0x0800;
const IPPROTO_ICMP = 1;
const IPPROTO_UDP = 17;

pub const Slirp = struct {
    guest_ip: [4]u8 = .{ 10, 0, 2, 15 },
    gateway_ip: [4]u8 = .{ 10, 0, 2, 2 },
    dns_ip: [4]u8 = .{ 10, 0, 2, 3 },
    mask: [4]u8 = .{ 255, 255, 255, 0 },
    /// The virtual gateway's MAC (locally administered). The guest's MAC matches
    /// virtio_net.zig's default.
    gateway_mac: [6]u8 = .{ 0x52, 0x54, 0x00, 0x12, 0x35, 0x02 },
    guest_mac: [6]u8 = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 },

    /// Sink for frames we send to the guest (wired to Net.pushRx).
    out_fn: ?*const fn (ctx: *anyopaque, frame: []const u8) void = null,
    out_ctx: ?*anyopaque = null,

    scratch: [2048]u8 = undefined,

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
        if (dport == 67) self.handleDhcp(frame, ihl); // BOOTP/DHCP server port
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
