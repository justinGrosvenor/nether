//! QEMU fw_cfg device, traditional PIO interface. The selector register
//! (0x510) picks an item; the data register (0x511) streams its bytes. OVMF
//! reads memory sizing, ACPI tables, the ACPI linker/loader, and SMBIOS through
//! this channel.
//!
//! Scope: PIO only. The DMA interface (and thus the feature bit) is not yet
//! advertised, so OVMF falls back to PIO. DMA, and serving the ACPI table set
//! plus the etc/table-loader linker/loader script, are the next steps.

const std = @import("std");
const io = @import("../chipset/io.zig");

pub const FwCfg = struct {
    selector: u16 = 0,
    offset: usize = 0,
    files: [max_files]File = undefined,
    file_count: usize = 0,
    dir: [dir_cap]u8 = undefined,
    dir_len: usize = 0,
    id_le: [4]u8 = .{ 1, 0, 0, 0 }, // feature bit 0 (traditional); no DMA

    pub const File = struct { key: u16, name: []const u8, data: []const u8 };

    const max_files = 16;
    const entry_size = 64; // FWCfgFile: size(4) select(2) reserved(2) name(56)
    const dir_cap = 4 + max_files * entry_size;

    const base = 0x510;
    const span = 12;
    const sel_port = 0x510;
    const data_port = 0x511;

    const key_signature = 0x0000;
    const key_id = 0x0001;
    const key_file_dir = 0x0019;
    const key_file_first = 0x0020;

    /// Register a named blob. It gets the next file key and appears in the
    /// directory (rebuilt when the guest selects FILE_DIR).
    pub fn addFile(self: *FwCfg, name: []const u8, data: []const u8) error{TooManyFiles}!void {
        if (self.file_count == max_files) return error.TooManyFiles;
        self.files[self.file_count] = .{
            .key = @intCast(key_file_first + self.file_count),
            .name = name,
            .data = data,
        };
        self.file_count += 1;
    }

    pub fn device(self: *FwCfg) io.PioDevice {
        return .{ .ptr = self, .base = base, .len = span, .out_fn = onOut, .in_fn = onIn };
    }

    fn rebuildDir(self: *FwCfg) void {
        std.mem.writeInt(u32, self.dir[0..4], @intCast(self.file_count), .big);
        var off: usize = 4;
        for (self.files[0..self.file_count]) |f| {
            std.mem.writeInt(u32, self.dir[off..][0..4], @intCast(f.data.len), .big);
            std.mem.writeInt(u16, self.dir[off + 4 ..][0..2], f.key, .big);
            std.mem.writeInt(u16, self.dir[off + 6 ..][0..2], 0, .big); // reserved
            @memset(self.dir[off + 8 ..][0..56], 0);
            const n = @min(f.name.len, 55);
            @memcpy(self.dir[off + 8 ..][0..n], f.name[0..n]);
            off += entry_size;
        }
        self.dir_len = off;
    }

    fn selectedData(self: *FwCfg) []const u8 {
        return switch (self.selector) {
            key_signature => "QEMU",
            key_id => &self.id_le,
            key_file_dir => self.dir[0..self.dir_len],
            else => {
                for (self.files[0..self.file_count]) |f| {
                    if (f.key == self.selector) return f.data;
                }
                return &[_]u8{};
            },
        };
    }

    fn onOut(ptr: *anyopaque, p: u16, size: u8, value: u32) void {
        _ = size;
        const self: *FwCfg = @ptrCast(@alignCast(ptr));
        if (p == sel_port) {
            self.selector = @truncate(value);
            self.offset = 0;
            if (self.selector == key_file_dir) self.rebuildDir();
        }
        // Data writes (writable items) and DMA ports are ignored for now.
    }

    fn onIn(ptr: *anyopaque, p: u16, size: u8) u32 {
        _ = size;
        const self: *FwCfg = @ptrCast(@alignCast(ptr));
        if (p != data_port) return 0;
        const d = self.selectedData();
        const v: u8 = if (self.offset < d.len) d[self.offset] else 0;
        self.offset += 1;
        return v;
    }
};

fn readItem(fw: *FwCfg, key: u16, out: []u8) void {
    const dev = fw.device();
    dev.out_fn(dev.ptr, 0x510, 2, key);
    for (out) |*b| b.* = @intCast(dev.in_fn(dev.ptr, 0x511, 1));
}

test "signature and id items" {
    var fw = FwCfg{};
    var sig: [4]u8 = undefined;
    readItem(&fw, 0x0000, &sig);
    try std.testing.expectEqualSlices(u8, "QEMU", &sig);

    var id: [4]u8 = undefined;
    readItem(&fw, 0x0001, &id);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, &id, .little));
}

test "files appear in the directory and read back" {
    var fw = FwCfg{};
    try fw.addFile("etc/table-loader", "PAYLOAD");

    // Directory: big-endian count, then one entry.
    var count: [4]u8 = undefined;
    readItem(&fw, 0x0019, &count);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, &count, .big));

    // The file reads back at its assigned key (0x0020).
    var payload: [7]u8 = undefined;
    readItem(&fw, 0x0020, &payload);
    try std.testing.expectEqualSlices(u8, "PAYLOAD", &payload);
}
