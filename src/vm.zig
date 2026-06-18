//! The VMM core: a `Vm` owning the KVM and VM fds plus guest memory, and a
//! `Vcpu` owning its fd, the shared run page, and the KVM_RUN loop. Allocator is
//! injected for the embeddable contract (swerver hosts this); memory regions and
//! the device set are fixed-capacity for Phase 0 and grow later.

const std = @import("std");
const linux = std.os.linux;
const kvm = @import("kvm.zig");
const io = @import("io.zig");
const pwr = @import("power.zig");
const irqchip = @import("irqchip.zig");

const PROT_RW = linux.PROT.READ | linux.PROT.WRITE;
const max_regions = 8;

pub const Error = error{
    BadApiVersion,
    SyscallFailed,
    TooManyRegions,
    NotMapped,
} || kvm.Error;

fn sys(r: usize, comptime what: []const u8) Error!usize {
    return switch (linux.errno(r)) {
        .SUCCESS => r,
        else => |e| {
            std.debug.print("[nether] {s} failed: {s}\n", .{ what, @tagName(e) });
            return error.SyscallFailed;
        },
    };
}

pub const Region = struct {
    slot: u32,
    guest_phys: u64,
    host: []u8,
};

pub const Vm = struct {
    allocator: std.mem.Allocator,
    kvm_fd: i32,
    vm_fd: i32,
    regions: [max_regions]Region = undefined,
    region_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Error!Vm {
        const kvm_fd: i32 = @intCast(try sys(
            linux.open("/dev/kvm", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0),
            "open /dev/kvm",
        ));
        errdefer _ = linux.close(kvm_fd);

        const api = try kvm.ioctl(kvm_fd, kvm.GET_API_VERSION, 0);
        if (api != kvm.API_VERSION) return error.BadApiVersion;

        const vm_fd: i32 = @intCast(try kvm.ioctl(kvm_fd, kvm.CREATE_VM, 0));
        return .{ .allocator = allocator, .kvm_fd = kvm_fd, .vm_fd = vm_fd };
    }

    pub fn deinit(self: *Vm) void {
        for (self.regions[0..self.region_count]) |r| {
            _ = linux.munmap(r.host.ptr, r.host.len);
        }
        _ = linux.close(self.vm_fd);
        _ = linux.close(self.kvm_fd);
    }

    /// Map `size` bytes of host memory and register it as guest physical memory
    /// at `guest_phys`. Returns the host-side slice for loading code/data.
    pub fn addMemory(self: *Vm, slot: u32, guest_phys: u64, size: usize) Error![]u8 {
        if (self.region_count == max_regions) return error.TooManyRegions;

        const addr = try sys(linux.mmap(
            null,
            size,
            PROT_RW,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ), "mmap guest ram");
        const host: [*]u8 = @ptrFromInt(addr);
        const slice = host[0..size];

        const region = kvm.UserspaceMemoryRegion{
            .slot = slot,
            .flags = 0,
            .guest_phys_addr = guest_phys,
            .memory_size = size,
            .userspace_addr = addr,
        };
        _ = try kvm.ioctl(self.vm_fd, kvm.SET_USER_MEMORY_REGION, @intFromPtr(&region));

        self.regions[self.region_count] = .{ .slot = slot, .guest_phys = guest_phys, .host = slice };
        self.region_count += 1;
        return slice;
    }

    /// Return a host slice for the guest physical range, or NotMapped.
    fn guestSlice(self: *Vm, gpa: u64, len: usize) Error![]u8 {
        for (self.regions[0..self.region_count]) |r| {
            if (gpa >= r.guest_phys and gpa + len <= r.guest_phys + r.host.len) {
                const off: usize = @intCast(gpa - r.guest_phys);
                return r.host[off .. off + len];
            }
        }
        return error.NotMapped;
    }

    /// Copy `bytes` into guest physical memory at `gpa`.
    pub fn guestWrite(self: *Vm, gpa: u64, bytes: []const u8) Error!void {
        @memcpy(try self.guestSlice(gpa, bytes.len), bytes);
    }

    /// Zero `len` bytes of guest physical memory at `gpa`.
    pub fn guestZero(self: *Vm, gpa: u64, len: usize) Error!void {
        @memset(try self.guestSlice(gpa, len), 0);
    }

    /// Enable the split irqchip (in-kernel LAPIC, userspace IOAPIC/PIC). Must be
    /// called before creating vCPUs.
    pub fn enableSplitIrqchip(self: *Vm) Error!void {
        try irqchip.enableSplit(self.vm_fd, irqchip.default_gsis);
    }

    pub fn createVcpu(self: *Vm, id: u32) Error!Vcpu {
        return Vcpu.init(self.kvm_fd, self.vm_fd, id);
    }
};

pub const Vcpu = struct {
    fd: i32,
    run_page: *kvm.Run,
    run_mem: []u8,

    pub const StopReason = enum { halted, shutdown, reset };

    fn init(kvm_fd: i32, vm_fd: i32, id: u32) Error!Vcpu {
        const fd: i32 = @intCast(try kvm.ioctl(vm_fd, kvm.CREATE_VCPU, id));
        errdefer _ = linux.close(fd);

        const size = try kvm.ioctl(kvm_fd, kvm.GET_VCPU_MMAP_SIZE, 0);
        const addr = try sys(linux.mmap(
            null,
            size,
            PROT_RW,
            .{ .TYPE = .SHARED },
            fd,
            0,
        ), "mmap kvm_run");
        const ptr: [*]u8 = @ptrFromInt(addr);
        return .{
            .fd = fd,
            .run_page = @ptrCast(@alignCast(ptr)),
            .run_mem = ptr[0..size],
        };
    }

    pub fn deinit(self: *Vcpu) void {
        _ = linux.munmap(self.run_mem.ptr, self.run_mem.len);
        _ = linux.close(self.fd);
    }

    /// Put the vCPU in 16-bit real mode with execution starting at `ip`. CS base
    /// is cleared so the linear address equals `ip`.
    pub fn setRealModeEntry(self: *Vcpu, ip: u64) Error!void {
        var sregs: kvm.Sregs = undefined;
        _ = try kvm.ioctl(self.fd, kvm.GET_SREGS, @intFromPtr(&sregs));
        sregs.cs.base = 0;
        sregs.cs.selector = 0;
        _ = try kvm.ioctl(self.fd, kvm.SET_SREGS, @intFromPtr(&sregs));

        var regs: kvm.Regs = std.mem.zeroes(kvm.Regs);
        regs.rip = ip;
        regs.rflags = 0x2; // reserved bit, must be set
        _ = try kvm.ioctl(self.fd, kvm.SET_REGS, @intFromPtr(&regs));
    }

    /// Set up 32-bit flat protected mode and enter at `eip` with EBX = `ebx`
    /// (the PVH ABI: EBX points at hvm_start_info). Paging is off; `gdt_base`
    /// must already hold a null/code/data GDT.
    pub fn setProtectedMode(self: *Vcpu, eip: u64, ebx: u64, gdt_base: u64) Error!void {
        var sregs: kvm.Sregs = undefined;
        _ = try kvm.ioctl(self.fd, kvm.GET_SREGS, @intFromPtr(&sregs));

        const code = kvm.Segment{
            .base = 0,
            .limit = 0xfffff,
            .selector = 0x08,
            .type_ = 0xb, // execute/read, accessed
            .present = 1,
            .dpl = 0,
            .db = 1, // 32-bit
            .s = 1,
            .l = 0,
            .g = 1, // 4 KiB granularity -> 4 GiB
            .avl = 0,
            .unusable = 0,
            .padding = 0,
        };
        var data = code;
        data.selector = 0x10;
        data.type_ = 0x3; // read/write, accessed

        sregs.cs = code;
        sregs.ds = data;
        sregs.es = data;
        sregs.ss = data;
        sregs.fs = data;
        sregs.gs = data;
        sregs.gdt.base = gdt_base;
        sregs.gdt.limit = 23; // 3 entries
        sregs.cr0 = 0x1; // PE set, paging off
        sregs.cr2 = 0;
        sregs.cr3 = 0;
        sregs.cr4 = 0;
        sregs.efer = 0;
        _ = try kvm.ioctl(self.fd, kvm.SET_SREGS, @intFromPtr(&sregs));

        var regs: kvm.Regs = std.mem.zeroes(kvm.Regs);
        regs.rip = eip;
        regs.rbx = ebx;
        regs.rflags = 0x2;
        _ = try kvm.ioctl(self.fd, kvm.SET_REGS, @intFromPtr(&regs));
    }

    /// Enter the guest repeatedly, dispatching I/O exits to `bus`, until the
    /// guest halts or a device requests a power transition via `power`.
    /// Unhandled exits are surfaced as errors.
    pub fn run(self: *Vcpu, bus: *io.Bus, power: *pwr.Power) !StopReason {
        while (true) {
            _ = try kvm.ioctl(self.fd, kvm.RUN, 0);
            switch (self.run_page.exit_reason) {
                kvm.EXIT_HLT => return .halted,
                kvm.EXIT_SHUTDOWN => return .shutdown,
                kvm.EXIT_IO => self.dispatchIo(bus),
                kvm.EXIT_MMIO => self.dispatchMmio(bus),
                kvm.EXIT_IOAPIC_EOI => {}, // userspace IOAPIC not yet implemented
                kvm.EXIT_FAIL_ENTRY => return error.FailEntry,
                kvm.EXIT_INTERNAL_ERROR => return error.InternalError,
                else => {
                    std.debug.print("[nether] unhandled exit reason {d}\n", .{self.run_page.exit_reason});
                    return error.UnhandledExit;
                },
            }
            // A device handled during this exit may have requested power-off/reset.
            if (power.action) |a| return switch (a) {
                .reset => .reset,
                .shutdown => .shutdown,
            };
        }
    }

    fn dispatchIo(self: *Vcpu, bus: *io.Bus) void {
        const e = self.run_page.exit.io;
        const data: [*]u8 = @as([*]u8, @ptrCast(self.run_page)) + @as(usize, @intCast(e.data_offset));
        const len: usize = e.size;
        var i: u32 = 0;
        while (i < e.count) : (i += 1) {
            const off = @as(usize, i) * len;
            const slot = data[off .. off + len];
            if (e.direction == kvm.EXIT_IO_OUT) {
                bus.pioOut(e.port, e.size, readValue(slot));
            } else {
                writeValue(slot, bus.pioIn(e.port, e.size));
            }
        }
    }

    fn dispatchMmio(self: *Vcpu, bus: *io.Bus) void {
        const m = &self.run_page.exit.mmio;
        const data = m.data[0..m.len];
        if (m.is_write != 0) {
            bus.mmioWrite(m.phys_addr, data);
        } else {
            bus.mmioRead(m.phys_addr, data); // fills data in the run page in place
        }
    }
};

/// Little-endian assemble up to 4 bytes into a value.
fn readValue(bytes: []const u8) u32 {
    var v: u32 = 0;
    for (bytes, 0..) |b, i| v |= @as(u32, b) << @intCast(i * 8);
    return v;
}

/// Little-endian scatter a value across the given bytes.
fn writeValue(bytes: []u8, value: u32) void {
    for (bytes, 0..) |*b, i| b.* = @truncate(value >> @intCast(i * 8));
}

test "value round-trips little-endian" {
    var buf = [_]u8{ 0, 0, 0, 0 };
    writeValue(&buf, 0x11223344);
    try std.testing.expectEqual(@as(u8, 0x44), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x11), buf[3]);
    try std.testing.expectEqual(@as(u32, 0x11223344), readValue(&buf));
}
