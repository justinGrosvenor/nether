//! KVM hypervisor backend (Linux, x86-64 guests). Implements the backend
//! interface that vm.zig's wrapper drives: a `Vm` owning the KVM/VM fds and the
//! IRQ setup, and a `Vcpu` owning its fd, the shared run page, and the KVM_RUN
//! loop with x86 exit dispatch and boot-entry setup. Guest RAM mmap and the
//! region table live in the shared layer (vm.zig); this layer only registers
//! regions with the kernel and runs vCPUs.
//!
//! Selected at comptime on Linux by backend.zig; the HVF backend is its peer.

const std = @import("std");
const linux = std.os.linux;
const kvm = @import("kvm.zig");
const io = @import("io.zig");
const pwr = @import("common/power.zig");
const irqchip = @import("irqchip.zig");
const ioapic = @import("ioapic.zig");
const hvtypes = @import("common/hvtypes.zig");

const StopReason = hvtypes.StopReason;
const readValue = hvtypes.readValue;
const writeValue = hvtypes.writeValue;

const Error = hvtypes.Error || kvm.Error;

fn sys(r: usize, comptime what: []const u8) Error!usize {
    return switch (linux.errno(r)) {
        .SUCCESS => r,
        else => |e| {
            std.debug.print("[nether] {s} failed: {s}\n", .{ what, @tagName(e) });
            return error.SyscallFailed;
        },
    };
}

pub const Vm = struct {
    kvm_fd: i32,
    vm_fd: i32,

    pub fn init() Error!Vm {
        const kvm_fd: i32 = @intCast(try sys(
            linux.open("/dev/kvm", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0),
            "open /dev/kvm",
        ));
        errdefer _ = linux.close(kvm_fd);

        const api = try kvm.ioctl(kvm_fd, kvm.GET_API_VERSION, 0);
        if (api != kvm.API_VERSION) return error.BadApiVersion;

        const vm_fd: i32 = @intCast(try kvm.ioctl(kvm_fd, kvm.CREATE_VM, 0));
        return .{ .kvm_fd = kvm_fd, .vm_fd = vm_fd };
    }

    pub fn deinit(self: *Vm) void {
        _ = linux.close(self.vm_fd);
        _ = linux.close(self.kvm_fd);
    }

    /// mmap host RAM and register it as guest physical memory at `guest_phys`.
    /// Returns the host slice.
    pub fn mapMemory(self: *Vm, slot: u32, guest_phys: u64, size: usize) Error![]u8 {
        const addr = try sys(linux.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ), "mmap guest ram");
        const host: [*]u8 = @ptrFromInt(addr);

        const region = kvm.UserspaceMemoryRegion{
            .slot = slot,
            .flags = 0,
            .guest_phys_addr = guest_phys,
            .memory_size = size,
            .userspace_addr = addr,
        };
        _ = try kvm.ioctl(self.vm_fd, kvm.SET_USER_MEMORY_REGION, @intFromPtr(&region));
        return host[0..size];
    }

    pub fn unmapMemory(self: *Vm, host: []u8) void {
        _ = self;
        _ = linux.munmap(host.ptr, host.len);
    }

    /// Split irqchip: in-kernel LAPIC, userspace IOAPIC/PIC. Before any vCPU.
    pub fn setupIrq(self: *Vm) Error!void {
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

    fn init(kvm_fd: i32, vm_fd: i32, id: u32) Error!Vcpu {
        const fd: i32 = @intCast(try kvm.ioctl(vm_fd, kvm.CREATE_VCPU, id));
        errdefer _ = linux.close(fd);

        // CPUID: without it the guest sees no features (e.g. long mode), so the
        // kernel's EFER.LME write would fault. Copy KVM's supported set through.
        var cpuid = kvm.Cpuid2{ .nent = 128 };
        _ = try kvm.ioctl(kvm_fd, kvm.GET_SUPPORTED_CPUID, @intFromPtr(&cpuid));
        // GET_SUPPORTED_CPUID leaks the host core's APIC ID; rewrite it to this
        // vCPU's LAPIC id so MSI destinations match (otherwise completions drop).
        var ci: usize = 0;
        while (ci < cpuid.nent) : (ci += 1) {
            const e = &cpuid.entries[ci];
            switch (e.function) {
                1 => e.ebx = (e.ebx & 0x00ffffff) | (id << 24),
                0xb, 0x1f => e.edx = id,
                else => {},
            }
        }
        _ = try kvm.ioctl(fd, kvm.SET_CPUID2, @intFromPtr(&cpuid));

        const size = try kvm.ioctl(kvm_fd, kvm.GET_VCPU_MMAP_SIZE, 0);
        const addr = try sys(linux.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
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
            .limit = 0xffffffff, // byte-granular limit in the VMCS: full 4 GiB
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
    pub fn run(self: *Vcpu, bus: *io.Bus, power: *pwr.Power, apic: ?*ioapic.IoApic) !StopReason {
        while (true) {
            _ = try kvm.ioctl(self.fd, kvm.RUN, 0);
            switch (self.run_page.exit_reason) {
                kvm.EXIT_HLT => return .halted,
                kvm.EXIT_SHUTDOWN => {
                    self.dumpState("shutdown");
                    return .shutdown;
                },
                kvm.EXIT_IO => self.dispatchIo(bus),
                kvm.EXIT_MMIO => self.dispatchMmio(bus),
                kvm.EXIT_IOAPIC_EOI => if (apic) |a| a.eoi(self.run_page.exit.eoi.vector),
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

    fn dumpState(self: *Vcpu, why: []const u8) void {
        var regs: kvm.Regs = undefined;
        var sregs: kvm.Sregs = undefined;
        _ = kvm.ioctl(self.fd, kvm.GET_REGS, @intFromPtr(&regs)) catch {};
        _ = kvm.ioctl(self.fd, kvm.GET_SREGS, @intFromPtr(&sregs)) catch {};
        std.debug.print(
            "[nether] {s}: rip=0x{x} rsp=0x{x} cr0=0x{x} cr2=0x{x} cr3=0x{x} cr4=0x{x} efer=0x{x}\n",
            .{ why, regs.rip, regs.rsp, sregs.cr0, sregs.cr2, sregs.cr3, sregs.cr4, sregs.efer },
        );
        const cs = sregs.cs;
        std.debug.print(
            "[nether]   cs: base=0x{x} limit=0x{x} sel=0x{x} type=0x{x} present={d} s={d} dpl={d} db={d} l={d} g={d}\n",
            .{ cs.base, cs.limit, cs.selector, cs.type_, cs.present, cs.s, cs.dpl, cs.db, cs.l, cs.g },
        );
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
