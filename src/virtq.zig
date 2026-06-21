//! Split virtqueue (virtio 1.x). Consumes the available ring, walks descriptor
//! chains, and publishes to the used ring. This parses attacker-controlled guest
//! data, so every guest access goes through a bounds-checked GuestMem and chain
//! walking is capped at the queue size to defeat circular/over-long chains.

const std = @import("std");

pub const DESC_F_NEXT = 1;
pub const DESC_F_WRITE = 2; // device writes (driver reads)
pub const DESC_F_INDIRECT = 4;

/// A view of guest RAM as a contiguous span starting at physical `base`. Every
/// access is bounds-checked; out-of-range reads yield 0 and writes are dropped,
/// so a malicious ring can never steer us outside the region.
pub const GuestMem = struct {
    bytes: []u8,
    base: u64,

    pub fn slice(self: GuestMem, gpa: u64, len: usize) ?[]u8 {
        if (gpa < self.base) return null;
        const off = gpa - self.base;
        // Overflow-safe bound: a guest can make `gpa` (hence `off`) huge, so never
        // compute off+len (it could wrap past the end). Compare against the room left.
        if (off > self.bytes.len or len > self.bytes.len - off) return null;
        return self.bytes[@intCast(off)..][0..len];
    }
    fn r16(self: GuestMem, gpa: u64) u16 {
        const s = self.slice(gpa, 2) orelse return 0;
        return std.mem.readInt(u16, s[0..2], .little);
    }
    fn r32(self: GuestMem, gpa: u64) u32 {
        const s = self.slice(gpa, 4) orelse return 0;
        return std.mem.readInt(u32, s[0..4], .little);
    }
    fn r64(self: GuestMem, gpa: u64) u64 {
        const s = self.slice(gpa, 8) orelse return 0;
        return std.mem.readInt(u64, s[0..8], .little);
    }
    fn w16(self: GuestMem, gpa: u64, v: u16) void {
        const s = self.slice(gpa, 2) orelse return;
        std.mem.writeInt(u16, s[0..2], v, .little);
    }
    fn w32(self: GuestMem, gpa: u64, v: u32) void {
        const s = self.slice(gpa, 4) orelse return;
        std.mem.writeInt(u32, s[0..4], v, .little);
    }
};

const Desc = struct { addr: u64, len: u32, flags: u16, next: u16 };

/// One buffer of a descriptor chain. `writable` means the device writes it.
pub const Buffer = struct { addr: u64, len: u32, writable: bool };

pub const Virtqueue = struct {
    size: u16,
    desc: u64, // descriptor table address
    avail: u64, // available ring address
    used: u64, // used ring address
    last_avail: u16 = 0, // next available index to consume
    used_idx: u16 = 0, // our shadow of the used ring index

    fn availIdx(self: Virtqueue, m: GuestMem) u16 {
        return m.r16(self.avail + 2);
    }

    /// True if the driver has offered a chain we have not consumed.
    pub fn hasNext(self: Virtqueue, m: GuestMem) bool {
        return self.last_avail != self.availIdx(m);
    }

    /// Pop the head descriptor index of the next available chain, or null.
    pub fn next(self: *Virtqueue, m: GuestMem) ?u16 {
        if (self.size == 0) return null; // guest may set size 0; never modulo by it
        if (!self.hasNext(m)) return null;
        const slot = self.last_avail % self.size;
        const head = m.r16(self.avail + 4 + @as(u64, slot) * 2);
        self.last_avail +%= 1;
        return head;
    }

    fn readDesc(self: Virtqueue, m: GuestMem, idx: u16) Desc {
        const a = self.desc + @as(u64, idx) * 16;
        return .{ .addr = m.r64(a), .len = m.r32(a + 8), .flags = m.r16(a + 12), .next = m.r16(a + 14) };
    }

    pub fn chain(self: *Virtqueue, m: GuestMem, head: u16) ChainIter {
        return .{ .vq = self, .mem = m, .idx = head, .seen = 0, .done = false };
    }

    /// Publish a completed chain (head index, bytes written) to the used ring.
    pub fn complete(self: *Virtqueue, m: GuestMem, head: u16, written: u32) void {
        if (self.size == 0) return; // never modulo by a guest-chosen zero size
        const slot = self.used_idx % self.size;
        const r = self.used + 4 + @as(u64, slot) * 8;
        m.w32(r, head); // used elem id
        m.w32(r + 4, written); // used elem len
        self.used_idx +%= 1;
        m.w16(self.used + 2, self.used_idx); // publish new used idx
    }
};

pub const ChainIter = struct {
    vq: *Virtqueue,
    mem: GuestMem,
    idx: u16,
    seen: u16,
    done: bool,

    pub fn next(self: *ChainIter) ?Buffer {
        // Stop on end-of-chain, an out-of-range index, or after at most `size`
        // descriptors (circular-chain guard).
        if (self.done or self.idx >= self.vq.size or self.seen >= self.vq.size) {
            self.done = true;
            return null;
        }
        const d = self.vq.readDesc(self.mem, self.idx);
        self.seen += 1;
        const buf = Buffer{ .addr = d.addr, .len = d.len, .writable = d.flags & DESC_F_WRITE != 0 };
        if (d.flags & DESC_F_NEXT != 0) self.idx = d.next else self.done = true;
        return buf;
    }
};

// --- tests -----------------------------------------------------------------

const layout = struct {
    const desc = 0x0;
    const avail = 0x100;
    const used = 0x200;
    const size = 4;
};

fn writeDesc(buf: []u8, idx: usize, addr: u64, len: u32, flags: u16, nxt: u16) void {
    const a = layout.desc + idx * 16;
    std.mem.writeInt(u64, buf[a..][0..8], addr, .little);
    std.mem.writeInt(u32, buf[a + 8 ..][0..4], len, .little);
    std.mem.writeInt(u16, buf[a + 12 ..][0..2], flags, .little);
    std.mem.writeInt(u16, buf[a + 14 ..][0..2], nxt, .little);
}

test "consumes a two-descriptor chain and publishes to used" {
    var ram = [_]u8{0} ** 4096;
    const m = GuestMem{ .bytes = &ram, .base = 0 };

    writeDesc(&ram, 0, 0x800, 16, DESC_F_NEXT, 1); // device-readable header
    writeDesc(&ram, 1, 0x900, 512, DESC_F_WRITE, 0); // device-writable data
    std.mem.writeInt(u16, ram[layout.avail + 2 ..][0..2], 1, .little); // avail.idx = 1
    std.mem.writeInt(u16, ram[layout.avail + 4 ..][0..2], 0, .little); // ring[0] = desc 0

    var vq = Virtqueue{ .size = layout.size, .desc = layout.desc, .avail = layout.avail, .used = layout.used };
    try std.testing.expect(vq.hasNext(m));
    const head = vq.next(m).?;
    try std.testing.expectEqual(@as(u16, 0), head);

    var it = vq.chain(m, head);
    const b0 = it.next().?;
    try std.testing.expectEqual(@as(u64, 0x800), b0.addr);
    try std.testing.expectEqual(false, b0.writable);
    const b1 = it.next().?;
    try std.testing.expectEqual(@as(u64, 0x900), b1.addr);
    try std.testing.expectEqual(true, b1.writable);
    try std.testing.expect(it.next() == null);

    vq.complete(m, head, 200);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ram[layout.used + 2 ..][0..2], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, ram[layout.used + 4 ..][0..4], .little)); // id
    try std.testing.expectEqual(@as(u32, 200), std.mem.readInt(u32, ram[layout.used + 8 ..][0..4], .little)); // len
}

test "circular chain is bounded by queue size" {
    var ram = [_]u8{0} ** 4096;
    const m = GuestMem{ .bytes = &ram, .base = 0 };
    writeDesc(&ram, 0, 0x800, 8, DESC_F_NEXT, 0); // points at itself

    var vq = Virtqueue{ .size = layout.size, .desc = layout.desc, .avail = layout.avail, .used = layout.used };
    var it = vq.chain(m, 0);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, layout.size), n); // capped, did not hang
}

test "out-of-range guest access is rejected" {
    var ram = [_]u8{0} ** 64;
    const m = GuestMem{ .bytes = &ram, .base = 0x1000 };
    try std.testing.expect(m.slice(0x1000, 64) != null);
    try std.testing.expect(m.slice(0x1000, 65) == null); // past end
    try std.testing.expect(m.slice(0x0, 8) == null); // below base
    try std.testing.expect(m.slice(0x100000, 8) == null); // far above
}

test "size-0 queue never divides by zero" {
    var ram = [_]u8{0} ** 256;
    const m = GuestMem{ .bytes = &ram, .base = 0 };
    // A malicious guest leaves size 0 but advertises an available chain.
    std.mem.writeInt(u16, ram[0x40 + 2 ..][0..2], 1, .little); // avail.idx = 1
    var vq = Virtqueue{ .size = 0, .desc = 0, .avail = 0x40, .used = 0x80 };
    try std.testing.expect(vq.next(m) == null); // guarded: no %0 panic
    vq.complete(m, 0, 0); // no-op: no %0 panic
}

test "slice rejects overflowing gpa/len instead of wrapping" {
    var ram = [_]u8{0} ** 64;
    const m = GuestMem{ .bytes = &ram, .base = 0 };
    try std.testing.expect(m.slice(0xFFFF_FFFF_FFFF_FFF0, 64) == null); // off huge
    try std.testing.expect(m.slice(0, std.math.maxInt(usize)) == null); // len huge
    try std.testing.expect(m.slice(60, 8) == null); // off+len would exceed end
    try std.testing.expect(m.slice(56, 8) != null); // exactly fits
}
