//! Minimal ELF64 loader for PVH direct boot. Copies PT_LOAD segments into guest
//! memory and returns the PVH 32-bit entry point from the
//! XEN_ELFNOTE_PHYS32_ENTRY note (name "Xen", type 18). The guest-memory writer
//! is passed as `ctx` with `write(gpa, bytes)` and `zero(gpa, len)` methods.

const std = @import("std");

pub const Error = error{ BadElf, NoPvhEntry };

const PT_LOAD = 1;
const PT_NOTE = 4;
const EM_X86_64 = 62;
const PHYS32_ENTRY = 18;

fn rd16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn rd64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}
fn align4(n: u32) usize {
    return (@as(usize, n) + 3) & ~@as(usize, 3);
}

pub fn loadPvh(image: []const u8, ctx: anytype) !u64 {
    if (image.len < 64) return error.BadElf;
    if (!std.mem.eql(u8, image[0..4], "\x7fELF")) return error.BadElf;
    if (image[4] != 2) return error.BadElf; // ELFCLASS64
    if (image[5] != 1) return error.BadElf; // little-endian
    if (rd16(image, 18) != EM_X86_64) return error.BadElf;

    const phoff: usize = @intCast(rd64(image, 32));
    const phentsize = rd16(image, 54);
    const phnum = rd16(image, 56);

    // The image is host-supplied but still untrusted enough to validate: a
    // malformed vmlinux must not read out of bounds. A 64-bit phdr is 56 bytes;
    // require that and that the whole header table fits, so every rd*(image, ph+..)
    // below stays in range. phnum/phentsize are u16 so their product cannot wrap.
    if (phentsize < 56 or phoff > image.len or phnum * @as(usize, phentsize) > image.len - phoff) return error.BadElf;

    var entry: ?u64 = null;
    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const ph = phoff + i * phentsize;
        const p_type = rd32(image, ph + 0);
        const p_offset: usize = @intCast(rd64(image, ph + 8));
        const p_paddr = rd64(image, ph + 24);
        const p_filesz: usize = @intCast(rd64(image, ph + 32));
        const p_memsz = rd64(image, ph + 40);
        // Overflow-safe segment bound: never compute p_offset + p_filesz (a
        // malformed offset can wrap past the end); compare against the room left.
        if (p_offset > image.len or p_filesz > image.len - p_offset) return error.BadElf;
        const seg = image[p_offset .. p_offset + p_filesz];
        switch (p_type) {
            PT_LOAD => {
                try ctx.write(p_paddr, seg);
                if (p_memsz > p_filesz) {
                    // p_paddr is a full attacker-controlled u64; compute the .bss start
                    // overflow-safe rather than relying on the writer to reject it (an
                    // unchecked p_paddr + p_filesz would wrap/panic on a malformed image).
                    const bss_start = std.math.add(u64, p_paddr, p_filesz) catch return error.BadElf;
                    try ctx.zero(bss_start, @intCast(p_memsz - p_filesz));
                }
            },
            PT_NOTE => {
                if (findPvhNote(seg)) |e| entry = e;
            },
            else => {},
        }
    }
    return entry orelse error.NoPvhEntry;
}

fn findPvhNote(notes: []const u8) ?u64 {
    var p: usize = 0;
    while (p + 12 <= notes.len) {
        const namesz = rd32(notes, p);
        const descsz = rd32(notes, p + 4);
        const ntype = rd32(notes, p + 8);
        const name_off = p + 12;
        const desc_off = name_off + align4(namesz);
        if (desc_off + descsz > notes.len) break;
        if (ntype == PHYS32_ENTRY and namesz >= 3 and std.mem.eql(u8, notes[name_off .. name_off + 3], "Xen")) {
            if (descsz == 4) return rd32(notes, desc_off);
            if (descsz == 8) return rd64(notes, desc_off);
        }
        p = desc_off + align4(descsz);
    }
    return null;
}

test "loads PT_LOAD and finds the PVH entry note" {
    var img = [_]u8{0} ** 256;
    // ELF header
    @memcpy(img[0..4], "\x7fELF");
    img[4] = 2; // class 64
    img[5] = 1; // little-endian
    std.mem.writeInt(u16, img[18..20], EM_X86_64, .little);
    std.mem.writeInt(u64, img[32..40], 64, .little); // e_phoff
    std.mem.writeInt(u16, img[54..56], 56, .little); // e_phentsize
    std.mem.writeInt(u16, img[56..58], 2, .little); // e_phnum

    // phdr0: PT_LOAD, file offset 196, paddr 0x100000, filesz 4, memsz 8
    var ph: usize = 64;
    std.mem.writeInt(u32, img[ph + 0 ..][0..4], PT_LOAD, .little);
    std.mem.writeInt(u64, img[ph + 8 ..][0..8], 196, .little);
    std.mem.writeInt(u64, img[ph + 24 ..][0..8], 0x100000, .little);
    std.mem.writeInt(u64, img[ph + 32 ..][0..8], 4, .little);
    std.mem.writeInt(u64, img[ph + 40 ..][0..8], 8, .little);

    // phdr1: PT_NOTE, file offset 176, filesz 20
    ph = 120;
    std.mem.writeInt(u32, img[ph + 0 ..][0..4], PT_NOTE, .little);
    std.mem.writeInt(u64, img[ph + 8 ..][0..8], 176, .little);
    std.mem.writeInt(u64, img[ph + 32 ..][0..8], 20, .little);

    // note at 176: namesz 4, descsz 4, type 18, "Xen\0", desc 0x100000
    std.mem.writeInt(u32, img[176..180], 4, .little);
    std.mem.writeInt(u32, img[180..184], 4, .little);
    std.mem.writeInt(u32, img[184..188], PHYS32_ENTRY, .little);
    @memcpy(img[188..192], "Xen\x00");
    std.mem.writeInt(u32, img[192..196], 0x100000, .little);

    // segment bytes at 196
    @memcpy(img[196..200], &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });

    const Mock = struct {
        addr: u64 = 0,
        len: usize = 0,
        zeroed: usize = 0,
        fn write(self: *@This(), gpa: u64, bytes: []const u8) !void {
            self.addr = gpa;
            self.len = bytes.len;
        }
        fn zero(self: *@This(), gpa: u64, len: usize) !void {
            _ = gpa;
            self.zeroed = len;
        }
    };
    var m = Mock{};
    const entry = try loadPvh(&img, &m);
    try std.testing.expectEqual(@as(u64, 0x100000), entry);
    try std.testing.expectEqual(@as(u64, 0x100000), m.addr);
    try std.testing.expectEqual(@as(usize, 4), m.len);
    try std.testing.expectEqual(@as(usize, 4), m.zeroed); // memsz 8 - filesz 4
}
