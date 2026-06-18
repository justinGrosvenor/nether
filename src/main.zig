//! Nether — Phase 0: KVM skeleton.
//!
//! Create a VM and one vCPU, map a single guest RAM region, load a tiny
//! real-mode program that writes a message to the 16550 data port (COM1,
//! 0x3f8), and run it. Each `out dx, al` traps out as KVM_EXIT_IO; we forward
//! the byte to our stdout. The guest then `hlt`s and we stop.
//!
//! This is the spine every later phase hangs off: open /dev/kvm, set up memory,
//! enter the KVM_RUN loop, and dispatch on the exit reason. Nether is Linux-only
//! by definition, so we call `std.os.linux` syscalls directly.

const std = @import("std");
const linux = std.os.linux;
const kvm = @import("kvm.zig");

const GUEST_RAM_SIZE = 0x20000; // 128 KiB — ample for Phase 0
const CODE_LOAD_ADDR = 0x1000; // where the blob lives in guest physical memory
const COM1_DATA = 0x3f8; // 16550 transmit-holding register

const PROT_RW = linux.PROT.READ | linux.PROT.WRITE;

const message = "Nether lives — Phase 0: real-mode guest talking over COM1.\n";

/// Comptime-assemble a 16-bit real-mode program that prints `msg` byte by byte
/// to COM1, then halts. No loops or memory operands — just `mov al, c; out dx,
/// al` per character — so it is trivially correct.
fn buildBlob(comptime msg: []const u8) [3 + msg.len * 3 + 1]u8 {
    var buf: [3 + msg.len * 3 + 1]u8 = undefined;
    // mov dx, 0x3f8
    buf[0] = 0xBA;
    buf[1] = COM1_DATA & 0xff;
    buf[2] = (COM1_DATA >> 8) & 0xff;
    var i: usize = 3;
    for (msg) |c| {
        buf[i] = 0xB0; // mov al, imm8
        buf[i + 1] = c;
        buf[i + 2] = 0xEE; // out dx, al
        i += 3;
    }
    buf[i] = 0xF4; // hlt
    return buf;
}

/// Decode the raw syscall convention: a value in the `-errno` band is a failure.
fn sys(r: usize, comptime what: []const u8) !usize {
    return switch (linux.errno(r)) {
        .SUCCESS => r,
        else => |e| {
            std.debug.print("[nether] {s} failed: {s}\n", .{ what, @tagName(e) });
            return error.SyscallFailed;
        },
    };
}

pub fn main() !void {
    const kvm_fd: i32 = @intCast(try sys(
        linux.open("/dev/kvm", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0),
        "open /dev/kvm",
    ));
    defer _ = linux.close(kvm_fd);

    const api = try kvm.ioctl(kvm_fd, kvm.GET_API_VERSION, 0);
    if (api != kvm.API_VERSION) {
        std.debug.print("[nether] unexpected KVM API version {d}\n", .{api});
        return error.BadApiVersion;
    }

    const vm_fd: i32 = @intCast(try kvm.ioctl(kvm_fd, kvm.CREATE_VM, 0));
    defer _ = linux.close(vm_fd);

    // Guest RAM: one anonymous region mapped at guest physical 0.
    const ram_addr = try sys(linux.mmap(
        null,
        GUEST_RAM_SIZE,
        PROT_RW,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ), "mmap guest ram");
    const mem: [*]u8 = @ptrFromInt(ram_addr);
    defer _ = linux.munmap(mem, GUEST_RAM_SIZE);

    const blob = comptime buildBlob(message);
    @memcpy(mem[CODE_LOAD_ADDR .. CODE_LOAD_ADDR + blob.len], blob[0..]);

    const region = kvm.UserspaceMemoryRegion{
        .slot = 0,
        .flags = 0,
        .guest_phys_addr = 0,
        .memory_size = GUEST_RAM_SIZE,
        .userspace_addr = ram_addr,
    };
    _ = try kvm.ioctl(vm_fd, kvm.SET_USER_MEMORY_REGION, @intFromPtr(&region));

    const vcpu_fd: i32 = @intCast(try kvm.ioctl(vm_fd, kvm.CREATE_VCPU, 0));
    defer _ = linux.close(vcpu_fd);

    const mmap_size = try kvm.ioctl(kvm_fd, kvm.GET_VCPU_MMAP_SIZE, 0);
    const run_addr = try sys(linux.mmap(
        null,
        mmap_size,
        PROT_RW,
        .{ .TYPE = .SHARED },
        vcpu_fd,
        0,
    ), "mmap kvm_run");
    defer _ = linux.munmap(@as([*]const u8, @ptrFromInt(run_addr)), mmap_size);
    const run: *kvm.Run = @ptrFromInt(run_addr);

    // Real mode: clear the reset-vector CS base so linear addr == IP, then point
    // IP at the loaded blob. (Data segments already reset to base 0.)
    var sregs: kvm.Sregs = undefined;
    _ = try kvm.ioctl(vcpu_fd, kvm.GET_SREGS, @intFromPtr(&sregs));
    sregs.cs.base = 0;
    sregs.cs.selector = 0;
    _ = try kvm.ioctl(vcpu_fd, kvm.SET_SREGS, @intFromPtr(&sregs));

    var regs: kvm.Regs = std.mem.zeroes(kvm.Regs);
    regs.rip = CODE_LOAD_ADDR;
    regs.rflags = 0x2; // bit 1 is reserved-and-must-be-set
    _ = try kvm.ioctl(vcpu_fd, kvm.SET_REGS, @intFromPtr(&regs));

    try runLoop(vcpu_fd, run);
}

/// The KVM_RUN loop: enter the guest, then dispatch on why it exited. Phase 0
/// only services serial OUT and stops on HLT/SHUTDOWN; everything else is
/// surfaced loudly so the next device to need handling announces itself.
fn runLoop(vcpu_fd: i32, run: *kvm.Run) !void {
    while (true) {
        _ = try kvm.ioctl(vcpu_fd, kvm.RUN, 0);

        switch (run.exit_reason) {
            kvm.EXIT_HLT => {
                std.debug.print("\n[nether] guest halted — Phase 0 complete\n", .{});
                return;
            },
            kvm.EXIT_SHUTDOWN => {
                std.debug.print("\n[nether] guest shutdown\n", .{});
                return;
            },
            kvm.EXIT_IO => try handleIo(run),
            kvm.EXIT_MMIO => {
                const m = run.exit.mmio;
                std.debug.print(
                    "[nether] unhandled MMIO @0x{x} write={d} len={d}\n",
                    .{ m.phys_addr, m.is_write, m.len },
                );
                return error.UnhandledMmio;
            },
            kvm.EXIT_FAIL_ENTRY => {
                std.debug.print("[nether] KVM_EXIT_FAIL_ENTRY (vCPU could not enter)\n", .{});
                return error.FailEntry;
            },
            kvm.EXIT_INTERNAL_ERROR => {
                std.debug.print("[nether] KVM_EXIT_INTERNAL_ERROR\n", .{});
                return error.InternalError;
            },
            else => {
                std.debug.print("[nether] unhandled exit reason {d}\n", .{run.exit_reason});
                return error.UnhandledExit;
            },
        }
    }
}

/// Forward a serial-port OUT to stdout. The payload lives in the shared run
/// page at `data_offset`, `size * count` bytes long.
fn handleIo(run: *kvm.Run) !void {
    const io = run.exit.io;
    if (io.direction == kvm.EXIT_IO_OUT and io.port == COM1_DATA) {
        const base: [*]const u8 = @ptrCast(run);
        const off: usize = @intCast(io.data_offset);
        const len: usize = @as(usize, io.size) * @as(usize, io.count);
        _ = linux.write(1, base + off, len);
        return;
    }
    std.debug.print(
        "[nether] unhandled IO port=0x{x} dir={d} size={d}\n",
        .{ io.port, io.direction, io.size },
    );
}

test {
    std.testing.refAllDecls(@import("kvm.zig"));
}
