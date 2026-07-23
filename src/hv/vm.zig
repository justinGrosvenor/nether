//! The VMM core, hypervisor-agnostic. `Vm` owns guest memory (the host mmap and
//! the region table) and delegates the hypervisor-specific work - region
//! registration, IRQ setup, vCPU creation and the run loop - to the comptime
//! backend (KVM on Linux, HVF on macOS; see backend.zig). `Vcpu` is the
//! backend's vCPU type directly. Allocator is injected for the embeddable
//! contract (swerver hosts this).

const std = @import("std");
const backend = @import("../hv/backend.zig");
const hvtypes = @import("../common/hvtypes.zig");

const impl = backend.impl;
const max_regions = 8;

pub const Error = hvtypes.Error;
pub const StopReason = hvtypes.StopReason;

/// The vCPU is exactly the selected backend's type (run loop + boot entry).
pub const Vcpu = impl.Vcpu;

pub const Region = struct {
    slot: u32,
    guest_phys: u64,
    host: []u8,
};

pub const Vm = struct {
    allocator: std.mem.Allocator,
    /// The backend handle (KVM fds / HVF VM). Public so x86-only host code can
    /// reach the KVM vm_fd for the IOAPIC and MSI plumbing.
    hv: impl.Vm,
    regions: [max_regions]Region = undefined,
    region_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Vm {
        return .{ .allocator = allocator, .hv = try impl.Vm.init() };
    }

    pub fn deinit(self: *Vm) void {
        for (self.regions[0..self.region_count]) |r| {
            self.hv.unmapMemory(r.host);
        }
        self.hv.deinit();
    }

    /// Allocate `size` bytes of host memory and map it as guest physical memory
    /// at `guest_phys`. Returns the host-side slice for loading code/data. The
    /// host mmap and hypervisor mapping are the backend's job (KVM needs the
    /// userspace_addr; HVF needs hv_vm_map); this layer owns the region table.
    pub fn addMemory(self: *Vm, slot: u32, guest_phys: u64, size: usize) ![]u8 {
        if (self.region_count == max_regions) return error.TooManyRegions;

        const host = try self.hv.mapMemory(slot, guest_phys, size);

        self.regions[self.region_count] = .{ .slot = slot, .guest_phys = guest_phys, .host = host };
        self.region_count += 1;
        return host;
    }

    /// Like addMemory, but map the region copy-on-write from a snapshot image file
    /// (a fork shares the base's pages, copying only what the guest writes). Backend
    /// support is required (KVM MAP_PRIVATE of the image fd); the region table owns
    /// the returned slice for teardown the same as an anonymous region.
    pub fn addMemoryCow(self: *Vm, slot: u32, guest_phys: u64, size: usize, fd: i32, file_off: u64) ![]u8 {
        if (self.region_count == max_regions) return error.TooManyRegions;
        const host = try self.hv.mapMemoryCow(slot, guest_phys, size, fd, file_off);
        self.regions[self.region_count] = .{ .slot = slot, .guest_phys = guest_phys, .host = host };
        self.region_count += 1;
        return host;
    }

    /// Return a host slice for the guest physical range, or NotMapped.
    fn guestSlice(self: *Vm, gpa: u64, len: usize) Error![]u8 {
        for (self.regions[0..self.region_count]) |r| {
            if (gpa < r.guest_phys) continue;
            const off = gpa - r.guest_phys;
            // Overflow-safe bound (matches virtq.GuestMem.slice): a guest can make
            // `gpa` huge, so never compute `gpa + len` (it can wrap past the end).
            // Compare against the room left in the region instead.
            if (off > r.host.len or len > r.host.len - off) continue;
            const o: usize = @intCast(off);
            return r.host[o .. o + len];
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

    /// Copy `buf.len` bytes of guest physical memory at `gpa` into `buf`.
    pub fn guestReadInto(self: *Vm, gpa: u64, buf: []u8) Error!void {
        @memcpy(buf, try self.guestSlice(gpa, buf.len));
    }

    /// Enable the interrupt controller (KVM split irqchip / HVF GIC). Must be
    /// called before creating vCPUs.
    pub fn enableSplitIrqchip(self: *Vm) !void {
        try self.hv.setupIrq();
    }

    pub fn createVcpu(self: *Vm, id: u32) !Vcpu {
        return self.hv.createVcpu(id);
    }
};
