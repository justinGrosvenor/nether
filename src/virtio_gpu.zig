//! virtio-gpu backend (virtio 1.x, device id 16) - the visual render path. A
//! minimal 2D device: enough of the control protocol for a guest's `virtio_gpu`
//! driver to bring up one scanout and present a framebuffer, so a GUI/visual agent
//! can draw and the host can capture the frame.
//!
//! Implemented control commands (queue 0):
//!   GET_DISPLAY_INFO, RESOURCE_CREATE_2D, RESOURCE_ATTACH_BACKING, SET_SCANOUT,
//!   TRANSFER_TO_HOST_2D (no-op: we read the guest backing live), RESOURCE_FLUSH,
//!   RESOURCE_UNREF. Anything else gets ERR_UNSPEC. The cursor queue (1) is drained
//!   and acked (no host cursor overlay). No 3D/virgl, no EDID feature.
//!
//! The framebuffer lives in guest RAM (the scanout resource's attached backing,
//! which may be scattered pages), so `frame` reads it directly via GuestMem and
//! emits a PPM - no host-side copy needed on transfer/flush. All command fields are
//! guest-controlled, so every id/count/dimension is bounds-checked.

const std = @import("std");
const virtio = @import("virtio.zig");
const virtq = @import("virtq.zig");
const Lock = @import("lock.zig").Lock;
const trace = @import("trace.zig");

pub const VIRTIO_ID_GPU = 16;
pub const CONTROLQ: u16 = 0; // guest -> host commands
pub const CURSORQ: u16 = 1; // cursor updates (drained + acked, no overlay)

// virtio_gpu_ctrl_hdr (24 bytes): type, flags, fence_id, ctx_id, ring_idx+pad.
const HDR_LEN = 24;
const FLAG_FENCE: u32 = 1 << 0;

// Command types.
const CMD_GET_DISPLAY_INFO: u32 = 0x0100;
const CMD_RESOURCE_CREATE_2D: u32 = 0x0101;
const CMD_RESOURCE_UNREF: u32 = 0x0102;
const CMD_SET_SCANOUT: u32 = 0x0103;
const CMD_RESOURCE_FLUSH: u32 = 0x0104;
const CMD_TRANSFER_TO_HOST_2D: u32 = 0x0105;
const CMD_RESOURCE_ATTACH_BACKING: u32 = 0x0106;
const CMD_RESOURCE_DETACH_BACKING: u32 = 0x0107;
// Response types.
const RESP_OK_NODATA: u32 = 0x1100;
const RESP_OK_DISPLAY_INFO: u32 = 0x1101;
const RESP_ERR_UNSPEC: u32 = 0x1200;

const MAX_SCANOUTS = 16;
const MAX_RES = 64; // resource-id table
const MAX_ENTRIES = 4096; // backing pages for the framebuffer (16 MiB at 4 KiB)
const BYTES_PER_PIXEL = 4;

const Resource = struct { used: bool = false, width: u32 = 0, height: u32 = 0, format: u32 = 0 };
const Entry = struct { addr: u64, len: u32 };

pub const Gpu = struct {
    dev: *virtio.Device = undefined,
    attached: bool = false,
    lock: Lock = .{},

    width: u32 = 1024, // advertised display mode
    height: u32 = 768,

    resources: [MAX_RES]Resource = [_]Resource{.{}} ** MAX_RES,
    scanout_res: u32 = 0, // resource id bound to scanout 0 (0 = none)
    frame_ready: bool = false,

    // Backing for the framebuffer resource. We track a single backed resource (the
    // fbdev/simpledrm case): if the guest backs several, only the latest is
    // captured.
    backing_res: u32 = 0,
    backing_n: usize = 0,
    backing: [MAX_ENTRIES]Entry = undefined,

    cmd_scratch: [4096]u8 = undefined, // gathered command bytes
    resp_scratch: [HDR_LEN + MAX_SCANOUTS * 24]u8 = undefined, // largest response (display info)

    pub fn backend(self: *Gpu) virtio.Backend {
        return .{
            .ptr = self,
            .device_id = VIRTIO_ID_GPU,
            .num_queues = 2,
            .device_features = 0, // no VIRGL/EDID: 2D scanout only
            .notify = onNotify,
            .config_read = configRead,
        };
    }

    pub fn attach(self: *Gpu, dev: *virtio.Device) void {
        self.dev = dev;
        self.attached = true;
    }

    /// virtio_gpu_config: events_read(0), events_clear(4), num_scanouts(8),
    /// num_capsets(12). The guest reads num_scanouts to size its display array.
    fn configRead(ptr: *anyopaque, off: u16, size: u8) u32 {
        _ = ptr;
        _ = size;
        return switch (off) {
            8 => 1, // one scanout
            else => 0,
        };
    }

    fn onNotify(ptr: *anyopaque, dev: *virtio.Device, q: u16) void {
        const self = cast(ptr);
        self.dev = dev;
        self.attached = true;
        switch (q) {
            CONTROLQ => self.handleQueue(dev, CONTROLQ),
            CURSORQ => self.handleQueue(dev, CURSORQ),
            else => {},
        }
    }

    /// Drain a command queue: gather each chain's command bytes, dispatch, scatter
    /// the response into the chain's writable buffers, complete.
    fn handleQueue(self: *Gpu, dev: *virtio.Device, qid: u16) void {
        const mem = dev.memory();
        const vq = dev.queue(qid);
        var consumed = false;
        while (true) {
            self.lock.lock();
            const head = vq.next(mem) orelse {
                self.lock.unlock();
                break;
            };
            const cmd_len = gatherReadable(mem, vq, head, &self.cmd_scratch);
            const resp_len = if (qid == CONTROLQ)
                self.dispatch(mem, self.cmd_scratch[0..cmd_len])
            else
                self.ack(self.cmd_scratch[0..cmd_len]); // cursor: ack only
            const written = scatterWritable(mem, vq, head, self.resp_scratch[0..resp_len]);
            vq.complete(mem, head, written);
            self.lock.unlock();
            consumed = true;
        }
        if (consumed) dev.interruptQueue(qid);
    }

    /// Build a response header into resp_scratch echoing the command's fence, with
    /// response `rtype`; returns the header length (callers append any payload).
    fn respHdr(self: *Gpu, cmd: []const u8, rtype: u32) void {
        @memset(self.resp_scratch[0..HDR_LEN], 0);
        std.mem.writeInt(u32, self.resp_scratch[0..4], rtype, .little);
        if (cmd.len >= HDR_LEN) {
            const flags = std.mem.readInt(u32, cmd[4..8], .little) & FLAG_FENCE;
            std.mem.writeInt(u32, self.resp_scratch[4..8], flags, .little);
            @memcpy(self.resp_scratch[8..16], cmd[8..16]); // echo fence_id
        }
    }

    fn ack(self: *Gpu, cmd: []const u8) usize {
        self.respHdr(cmd, RESP_OK_NODATA);
        return HDR_LEN;
    }

    fn dispatch(self: *Gpu, mem: virtq.GuestMem, cmd: []const u8) usize {
        if (cmd.len < HDR_LEN) {
            self.respHdr(cmd, RESP_ERR_UNSPEC);
            return HDR_LEN;
        }
        const cmd_type = std.mem.readInt(u32, cmd[0..4], .little);
        switch (cmd_type) {
            CMD_GET_DISPLAY_INFO => {
                self.respHdr(cmd, RESP_OK_DISPLAY_INFO);
                // pmodes[MAX_SCANOUTS] of { rect{x,y,w,h}, enabled, flags }; scanout 0
                // enabled at our mode, the rest zero (disabled).
                @memset(self.resp_scratch[HDR_LEN..], 0);
                std.mem.writeInt(u32, self.resp_scratch[HDR_LEN + 8 ..][0..4], self.width, .little); // rect.width
                std.mem.writeInt(u32, self.resp_scratch[HDR_LEN + 12 ..][0..4], self.height, .little); // rect.height
                std.mem.writeInt(u32, self.resp_scratch[HDR_LEN + 16 ..][0..4], 1, .little); // enabled
                return HDR_LEN + MAX_SCANOUTS * 24;
            },
            CMD_RESOURCE_CREATE_2D => {
                if (cmd.len >= 40) {
                    const id = std.mem.readInt(u32, cmd[24..28], .little);
                    if (id != 0 and id < MAX_RES) {
                        self.resources[id] = .{
                            .used = true,
                            .format = std.mem.readInt(u32, cmd[28..32], .little),
                            .width = @min(std.mem.readInt(u32, cmd[32..36], .little), 4096),
                            .height = @min(std.mem.readInt(u32, cmd[36..40], .little), 4096),
                        };
                    }
                }
                self.respHdr(cmd, RESP_OK_NODATA);
                return HDR_LEN;
            },
            CMD_RESOURCE_ATTACH_BACKING => {
                if (cmd.len >= 32) {
                    const id = std.mem.readInt(u32, cmd[24..28], .little);
                    const nr = std.mem.readInt(u32, cmd[28..32], .little);
                    self.backing_res = id;
                    self.backing_n = 0;
                    var i: u32 = 0;
                    while (i < nr and self.backing_n < MAX_ENTRIES) : (i += 1) {
                        const at = 32 + @as(usize, i) * 16;
                        if (at + 12 > cmd.len) break;
                        self.backing[self.backing_n] = .{
                            .addr = std.mem.readInt(u64, cmd[at..][0..8], .little),
                            .len = std.mem.readInt(u32, cmd[at + 8 ..][0..4], .little),
                        };
                        self.backing_n += 1;
                    }
                }
                self.respHdr(cmd, RESP_OK_NODATA);
                return HDR_LEN;
            },
            CMD_SET_SCANOUT => {
                if (cmd.len >= 48) {
                    const scanout_id = std.mem.readInt(u32, cmd[40..44], .little);
                    const res_id = std.mem.readInt(u32, cmd[44..48], .little);
                    if (scanout_id == 0) self.scanout_res = res_id;
                }
                self.respHdr(cmd, RESP_OK_NODATA);
                return HDR_LEN;
            },
            CMD_RESOURCE_FLUSH => {
                self.frame_ready = true; // the backing now holds a presentable frame
                self.respHdr(cmd, RESP_OK_NODATA);
                return HDR_LEN;
            },
            CMD_TRANSFER_TO_HOST_2D => {
                // No-op: the backing IS the framebuffer and we read it live in frame().
                self.respHdr(cmd, RESP_OK_NODATA);
                return HDR_LEN;
            },
            CMD_RESOURCE_UNREF => {
                if (cmd.len >= 28) {
                    const id = std.mem.readInt(u32, cmd[24..28], .little);
                    if (id != 0 and id < MAX_RES) self.resources[id] = .{};
                    if (id == self.scanout_res) self.scanout_res = 0;
                    if (id == self.backing_res) self.backing_n = 0;
                }
                self.respHdr(cmd, RESP_OK_NODATA);
                return HDR_LEN;
            },
            CMD_RESOURCE_DETACH_BACKING => {
                if (cmd.len >= 28 and std.mem.readInt(u32, cmd[24..28], .little) == self.backing_res) self.backing_n = 0;
                self.respHdr(cmd, RESP_OK_NODATA);
                return HDR_LEN;
            },
            else => {
                trace.log("gpu unhandled cmd=0x{x}", .{cmd_type});
                self.respHdr(cmd, RESP_ERR_UNSPEC);
                return HDR_LEN;
            },
        }
        _ = mem;
    }

    /// Read `n` bytes (<= 8) from the framebuffer backing at byte offset `off`,
    /// walking the (offset-contiguous) backing entries. Returns 0 if out of range.
    fn readBacking(self: *const Gpu, mem: virtq.GuestMem, off: u64, base_entry: *usize, base_off: *u64) u32 {
        // Advance the cursor entry to the one containing `off`.
        while (base_entry.* < self.backing_n and off >= base_off.* + self.backing[base_entry.*].len) {
            base_off.* += self.backing[base_entry.*].len;
            base_entry.* += 1;
        }
        if (base_entry.* >= self.backing_n) return 0;
        const e = self.backing[base_entry.*];
        const within = off - base_off.*;
        if (within + 4 > e.len) return 0; // pixel would span entries (offsets are 4-aligned, pages aren't)
        const s = mem.slice(e.addr + within, 4) orelse return 0;
        return std.mem.readInt(u32, s[0..4], .little);
    }

    /// Capture the current scanout as a binary PPM (P6) into `out`. Pixels are read
    /// from the guest backing as 32bpp little-endian (byte order B,G,R,X = the
    /// common XRGB8888 fb) and emitted as RGB. Returns bytes written, or 0 if no
    /// frame is presentable / `out` is too small.
    /// Bytes a `frame` capture needs right now (0 if no presentable frame), so the
    /// caller can size the buffer.
    pub fn frameSize(self: *Gpu) usize {
        self.lock.lock();
        defer self.lock.unlock();
        const res = self.scanout_res;
        if (res == 0 or res >= MAX_RES or !self.resources[res].used) return 0;
        if (self.backing_res != res or self.backing_n == 0) return 0;
        const w = self.resources[res].width;
        const h = self.resources[res].height;
        if (w == 0 or h == 0) return 0;
        return @as(usize, w) * h * 3 + 32;
    }

    pub fn frame(self: *Gpu, out: []u8) usize {
        self.lock.lock();
        defer self.lock.unlock();
        if (!self.attached) return 0;
        const mem = self.dev.memory();
        const res = self.scanout_res;
        if (res == 0 or res >= MAX_RES or !self.resources[res].used) return 0;
        if (self.backing_res != res or self.backing_n == 0) return 0;
        const w = self.resources[res].width;
        const h = self.resources[res].height;
        if (w == 0 or h == 0) return 0;
        const need = @as(usize, w) * h * 3 + 32; // PPM body + header slack
        if (out.len < need) return 0;

        var n: usize = 0;
        n += (std.fmt.bufPrint(out[n..], "P6\n{d} {d}\n255\n", .{ w, h }) catch return 0).len;
        var entry: usize = 0;
        var entry_off: u64 = 0;
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const off = (@as(u64, y) * w + x) * BYTES_PER_PIXEL;
                const px = self.readBacking(mem, off, &entry, &entry_off);
                out[n] = @truncate(px >> 16); // R (XRGB LE: byte2)
                out[n + 1] = @truncate(px >> 8); // G
                out[n + 2] = @truncate(px); // B
                n += 3;
            }
        }
        return n;
    }
};

fn cast(ptr: *anyopaque) *Gpu {
    return @ptrCast(@alignCast(ptr));
}

/// Gather a chain's device-readable bytes (the command) into `buf`, capped.
fn gatherReadable(mem: virtq.GuestMem, vq: *virtq.Virtqueue, head: u16, buf: []u8) usize {
    var n: usize = 0;
    var it = vq.chain(mem, head);
    while (it.next()) |b| {
        if (b.writable) continue;
        const src = mem.slice(b.addr, b.len) orelse continue;
        const take = @min(buf.len - n, src.len);
        @memcpy(buf[n..][0..take], src[0..take]);
        n += take;
        if (n == buf.len) break;
    }
    return n;
}

/// Scatter a response across a chain's device-writable buffers; returns bytes written.
fn scatterWritable(mem: virtq.GuestMem, vq: *virtq.Virtqueue, head: u16, data: []const u8) u32 {
    var off: usize = 0;
    var it = vq.chain(mem, head);
    while (it.next()) |b| {
        if (!b.writable) continue;
        if (off == data.len) break;
        const dst = mem.slice(b.addr, b.len) orelse continue;
        const take = @min(dst.len, data.len - off);
        @memcpy(dst[0..take], data[off..][0..take]);
        off += take;
    }
    return @intCast(off);
}

// --- tests -----------------------------------------------------------------
// Drive the control queue with the exact command sequence a guest virtio_gpu
// driver issues to bring up one scanout, then verify the host captures the frame
// the guest "drew" into the backing.

const testing = std.testing;

const CTRL_DESC = 0x0000;
const CTRL_AVAIL = 0x0400;
const CTRL_USED = 0x0800;
const CMD_AT = 0x1000; // command buffer
const RESP_AT = 0x1400; // response buffer
const FB_AT = 0x2000; // framebuffer backing

fn gpuProgQueue(dev: *virtio.Device) void {
    dev.barWrite(0x16, 2, CONTROLQ);
    dev.barWrite(0x18, 2, 16);
    dev.barWrite(0x20, 4, CTRL_DESC);
    dev.barWrite(0x28, 4, CTRL_AVAIL);
    dev.barWrite(0x30, 4, CTRL_USED);
    dev.barWrite(0x1c, 2, 1);
}

/// Submit one command (cmd_len bytes at CMD_AT) as a readable+writable chain on
/// avail slot `slot`, kick the queue, return the response type from RESP_AT.
fn gpuSubmit(dev: *virtio.Device, ram: []u8, slot: u16, cmd_len: u32) u32 {
    // desc0 = command (readable, chains to desc1); desc1 = response (writable).
    std.mem.writeInt(u64, ram[CTRL_DESC..][0..8], CMD_AT, .little);
    std.mem.writeInt(u32, ram[CTRL_DESC + 8 ..][0..4], cmd_len, .little);
    std.mem.writeInt(u16, ram[CTRL_DESC + 12 ..][0..2], virtq.DESC_F_NEXT, .little);
    std.mem.writeInt(u16, ram[CTRL_DESC + 14 ..][0..2], 1, .little);
    std.mem.writeInt(u64, ram[CTRL_DESC + 16 ..][0..8], RESP_AT, .little);
    std.mem.writeInt(u32, ram[CTRL_DESC + 24 ..][0..4], 512, .little);
    std.mem.writeInt(u16, ram[CTRL_DESC + 28 ..][0..2], virtq.DESC_F_WRITE, .little);
    std.mem.writeInt(u16, ram[CTRL_AVAIL + 4 + @as(usize, slot) * 2 ..][0..2], 0, .little); // ring[slot] = desc 0
    std.mem.writeInt(u16, ram[CTRL_AVAIL + 2 ..][0..2], slot + 1, .little); // avail.idx
    dev.barWrite(0x2000, 4, CONTROLQ); // notify
    return std.mem.readInt(u32, ram[RESP_AT..][0..4], .little);
}

fn putHdr(ram: []u8, cmd_type: u32) void {
    @memset(ram[CMD_AT..][0..HDR_LEN], 0);
    std.mem.writeInt(u32, ram[CMD_AT..][0..4], cmd_type, .little);
}

test "gpu brings up a scanout and the host captures the drawn frame" {
    var ram = [_]u8{0} ** 16384;
    var gpu = Gpu{};
    var dev = virtio.Device.init(gpu.backend(), .{ .bytes = &ram, .base = 0 });
    gpuProgQueue(&dev);

    // GET_DISPLAY_INFO -> RESP_OK_DISPLAY_INFO with our 1024x768 mode on scanout 0.
    putHdr(&ram, CMD_GET_DISPLAY_INFO);
    try testing.expectEqual(RESP_OK_DISPLAY_INFO, gpuSubmit(&dev, &ram, 0, HDR_LEN));
    try testing.expectEqual(@as(u32, 1024), std.mem.readInt(u32, ram[RESP_AT + HDR_LEN + 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, ram[RESP_AT + HDR_LEN + 16 ..][0..4], .little)); // enabled

    // RESOURCE_CREATE_2D: id 1, format 2 (B8G8R8X8), 2x2.
    putHdr(&ram, CMD_RESOURCE_CREATE_2D);
    std.mem.writeInt(u32, ram[CMD_AT + 24 ..][0..4], 1, .little); // resource_id
    std.mem.writeInt(u32, ram[CMD_AT + 28 ..][0..4], 2, .little); // format
    std.mem.writeInt(u32, ram[CMD_AT + 32 ..][0..4], 2, .little); // width
    std.mem.writeInt(u32, ram[CMD_AT + 36 ..][0..4], 2, .little); // height
    try testing.expectEqual(RESP_OK_NODATA, gpuSubmit(&dev, &ram, 1, 40));

    // RESOURCE_ATTACH_BACKING: id 1, one entry {FB_AT, 16}.
    putHdr(&ram, CMD_RESOURCE_ATTACH_BACKING);
    std.mem.writeInt(u32, ram[CMD_AT + 24 ..][0..4], 1, .little); // resource_id
    std.mem.writeInt(u32, ram[CMD_AT + 28 ..][0..4], 1, .little); // nr_entries
    std.mem.writeInt(u64, ram[CMD_AT + 32 ..][0..8], FB_AT, .little); // entry.addr
    std.mem.writeInt(u32, ram[CMD_AT + 40 ..][0..4], 16, .little); // entry.len
    try testing.expectEqual(RESP_OK_NODATA, gpuSubmit(&dev, &ram, 2, 48));

    // SET_SCANOUT: scanout 0 <- resource 1.
    putHdr(&ram, CMD_SET_SCANOUT);
    std.mem.writeInt(u32, ram[CMD_AT + 32 ..][0..4], 2, .little); // rect.width
    std.mem.writeInt(u32, ram[CMD_AT + 36 ..][0..4], 2, .little); // rect.height
    std.mem.writeInt(u32, ram[CMD_AT + 40 ..][0..4], 0, .little); // scanout_id
    std.mem.writeInt(u32, ram[CMD_AT + 44 ..][0..4], 1, .little); // resource_id
    try testing.expectEqual(RESP_OK_NODATA, gpuSubmit(&dev, &ram, 3, 48));

    // "Draw": 4 pixels XRGB LE at FB_AT (B,G,R,X bytes) -> red, green, blue, white.
    const px = [_]u32{ 0x00FF0000, 0x0000FF00, 0x000000FF, 0x00FFFFFF };
    for (px, 0..) |p, i| std.mem.writeInt(u32, ram[FB_AT + i * 4 ..][0..4], p, .little);

    // FLUSH -> frame is presentable.
    putHdr(&ram, CMD_RESOURCE_FLUSH);
    std.mem.writeInt(u32, ram[CMD_AT + 40 ..][0..4], 1, .little); // resource_id
    try testing.expectEqual(RESP_OK_NODATA, gpuSubmit(&dev, &ram, 4, 48));
    try testing.expect(gpu.frame_ready);

    // Capture: PPM header + 4 pixels as RGB.
    var out: [256]u8 = undefined;
    const n = gpu.frame(&out);
    try testing.expect(n > 0);
    try testing.expect(std.mem.startsWith(u8, out[0..n], "P6\n2 2\n255\n"));
    const body = out[n - 12 .. n]; // 4 pixels * 3 bytes
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0, 0 }, body[0..3]); // red
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0xFF, 0 }, body[3..6]); // green
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0xFF }, body[6..9]); // blue
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFF, 0xFF }, body[9..12]); // white
}

test "gpu rejects an unknown command with ERR_UNSPEC" {
    var ram = [_]u8{0} ** 8192;
    var gpu = Gpu{};
    var dev = virtio.Device.init(gpu.backend(), .{ .bytes = &ram, .base = 0 });
    gpuProgQueue(&dev);
    putHdr(&ram, 0x0fff); // not a real command
    try testing.expectEqual(RESP_ERR_UNSPEC, gpuSubmit(&dev, &ram, 0, HDR_LEN));
}
