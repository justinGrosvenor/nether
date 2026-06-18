# Nether

A type-2 KVM-backed VMM in Zig. Modern guests only, no legacy hardware. Runs in
the layer below the guest, hence the name.

See [`docs/`](docs/README.md) for design, roadmap, and decisions.

## Status

Phase 1.5 substrate is in place: a VM/vCPU core with allocator injection, a
single-source-of-truth memory map, a port + MMIO exit dispatcher, the firmware
floor (16550 serial, RTC, ACPI PM block, 0xCF9 reset), the split irqchip with
eventfd/MSI plumbing, a fw_cfg device, and a minimal static ACPI generator.

**PVH direct boot** is wired end to end: it loads a PVH-capable `vmlinux` (and an
optional `initramfs`), places the ACPI tables and `hvm_start_info` in guest RAM,
and enters the kernel in 32-bit protected mode. The 16550 is complete enough for
the Linux 8250 driver to use `ttyS0`, so a booted kernel prints over serial.

If no `vmlinux` is present the binary runs a comptime real-mode blob that prints
over COM1 and triggers ACPI S5, as a smoke test.

## Build & run

Nether targets **Linux with `/dev/kvm`**. The build cross-compiles to
`x86_64-linux` by default, so it type-checks on any host; it can only *run* on a
Linux box with KVM and hardware virtualization enabled.

```sh
zig build              # cross-compile (x86_64-linux by default)
zig build run          # build + run (Linux host only)
zig build test         # run the test suite on the host
zig build -Dtarget=... # override the target
```

To PVH-boot a guest, place a PVH-capable `vmlinux` (and optionally an
`initramfs`) in the working directory before `zig build run`.

On a macOS host whose `xcode-select` points into Xcode.app (e.g. while doing iOS
work), native linking cannot find the SDK. Prefix any command that links a host
binary with the standalone Command Line Tools:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools zig build test
```

Cross-compilation is unaffected, so plain `zig build` (and `zig build -Dtarget=`)
still type-checks the Linux artifact without the prefix.

Expected smoke-test output (no `vmlinux` present) on a KVM host:

```
Nether lives. Phase 0: real-mode guest over COM1.
[nether] guest shutdown.
```

## Layout

```
build.zig          cross-compiles x86_64-linux; tests build for the host
src/root.zig       library root the host (swerver) consumes
src/kvm.zig        hand-rolled KVM ABI: ioctl numbers, structs, wrapper
src/vm.zig         Vm + Vcpu: memory, KVM_RUN loop, I/O dispatch, boot entry
src/io.zig         Bus: port + MMIO device dispatch spine
src/memmap.zig     guest physical memory map (single source of truth)
src/irqchip.zig    split irqchip: irqfd, ioeventfd, MSI injection
src/serial.zig     16550A UART (full register file, ttyS0)
src/rtc.zig        MC146818 RTC/CMOS
src/pm.zig         ACPI PM block: S5 soft-off, PM timer
src/reset.zig      0xCF9 reset control
src/fw_cfg.zig     QEMU fw_cfg device (PIO)
src/acpi.zig       minimal static ACPI table generator
src/elf.zig        ELF64 loader + PVH entry note
src/pvh.zig        PVH direct boot: start_info, modules, orchestration
src/main.zig       thin binary wrapper over the core
docs/              thesis.md · design.md · roadmap.md · decisions.md
```

Requires Zig 0.16.0.
