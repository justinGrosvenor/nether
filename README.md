# Nether

A type-2 KVM-backed VMM in Zig. Modern guests only, no legacy hardware. Runs in
the layer below the guest, hence the name.

**Documentation:** [docs.nether.dev](https://docs.nether.dev) (source in [`docs/`](docs/index.md)). Design, roadmap, and bringup guides live there.

## Status

**Verified on a bare-metal KVM host: Nether PVH-boots Linux 6.12 to an
interactive shell over virtio-pci.** The Phase 1.5 substrate is in place (a
VM/vCPU core with allocator injection, a single-source-of-truth memory map, a
port + MMIO exit dispatcher, the firmware floor, the split irqchip with
eventfd/MSI plumbing, fw_cfg, and a minimal static ACPI generator), and on top of
it:

- **PVH direct boot** end to end: loads a PVH-capable `vmlinux` (and optional
  `initramfs`), places the ACPI tables and `hvm_start_info` in guest RAM, enters
  the kernel in 32-bit protected mode.
- **Userspace IOAPIC** routing serial IRQ4, so the `ttyS0` console runs
  interactively instead of stalling at the 16550 FIFO.
- **virtio-blk reads and writes** end to end: the guest enumerates the device
  over the ACPI PCIe host bridge, claims its BAR, and reads/writes `/dev/vda`
  with MSI-X completions; writes land on the host disk image.
- **Continuous interactive stdin**: a host I/O thread feeds the serial RX and
  raises IRQ4 so an idle shell still receives input (offline-built and
  unit-tested; live verification pending the next box).
- **virtio-vsock** (the swerver<->guest channel): a pure protocol engine
  (header codec, connection state machine, credit flow control) plus the
  three-queue device glue, wired behind a `nether-vsock` marker with a host echo
  service on port 1234 (offline-built, unit- and fuzz-tested; live boot
  verification pending).
- **virtio-net** (the last Phase 3 datapath device): a tap-backed NIC with the
  two-queue datapath (guest TX frames written to a host tap, a reader thread
  pushing inbound frames to the guest RX), wired behind a `nether-net` marker
  (offline-built, unit- and fuzz-tested; live boot verification pending).

The hypervisor is now a **compile-time backend seam** (KVM on Linux/x86-64, Apple
Hypervisor.framework on macOS/aarch64), and the macOS/HVF path has reached **first
light**: a tiny aarch64 guest runs natively on Apple Silicon, prints over an MMIO
UART, and powers off - exercising `hv_vm_create`/`hv_vm_map`, the vCPU run loop,
and the data-abort (MMIO) decode. The aarch64 substrate (GIC, PL011, timer, PSCI)
and Linux boot are the next chunks. See [`docs/running-on-hvf.md`](docs/running-on-hvf.md).

If no `vmlinux` is present the binary runs a comptime real-mode blob that prints
over COM1 and triggers ACPI S5, as a smoke test. See
[`docs/bringup-notes.md`](docs/bringup-notes.md) for the hard-won KVM/PVH/virtio
gotchas behind all of the above.

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

On an Apple Silicon Mac the HVF backend is selected automatically; build natively,
codesign with the hypervisor entitlement (ad-hoc is fine for local dev), and run:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools zig build -Dtarget=native
codesign --sign - --entitlements nether.entitlements --force zig-out/bin/nether
./zig-out/bin/nether
```

See [`docs/running-on-hvf.md`](docs/running-on-hvf.md) for the macOS/aarch64 path.

Expected smoke-test output (no `vmlinux` present) on a KVM host:

```
Nether lives. Phase 0: real-mode guest over COM1.
[nether] guest shutdown.
```

## Layout

```
build.zig          cross-compiles x86_64-linux; tests build for the host
src/root.zig       library root the host (swerver) consumes
src/vm.zig         Vm + Vcpu: hypervisor-agnostic wrapper (memory + region table)
src/backend.zig    comptime hypervisor backend select (KVM on Linux, HVF on macOS)
src/hvtypes.zig    backend-agnostic shared types (StopReason, Error, LE helpers)
src/kvm_backend.zig KVM backend: KVM_RUN loop, x86 exit dispatch, boot entry
src/hvf_backend.zig HVF backend: Apple Hypervisor.framework, aarch64 (scaffold)
src/kvm.zig        hand-rolled KVM ABI: ioctl numbers, structs, wrapper
src/io.zig         Bus: port + MMIO device dispatch spine
src/memmap.zig     guest physical memory map (single source of truth)
src/irqchip.zig    split irqchip: irqfd, ioeventfd, MSI injection
src/ioapic.zig     userspace IOAPIC: redirection table -> MSI translation
src/lock.zig       per-device spin lock (the D3 concurrency primitive)
src/serial.zig     16550A UART (full register file, ttyS0, RX FIFO)
src/rtc.zig        MC146818 RTC/CMOS
src/pm.zig         ACPI PM block: S5 soft-off, PM timer
src/reset.zig      0xCF9 reset control
src/power.zig      power-transition signal (reset/shutdown)
src/fw_cfg.zig     QEMU fw_cfg device (PIO)
src/acpi.zig       minimal static ACPI table generator (+ dsdt.asl/.aml)
src/pci.zig        PCIe ECAM host bridge + config space
src/virtio.zig     virtio-pci-modern transport (config, BAR, MSI-X)
src/virtq.zig      split virtqueue (bounds-checked descriptor walk)
src/virtio_blk.zig virtio-blk backend (read/write/flush)
src/virtio_rng.zig virtio-rng backend
src/virtio_net.zig virtio-net backend (tap-backed NIC)
src/virtio_vsock.zig virtio-vsock protocol engine (swerver<->guest channel)
src/elf.zig        ELF64 loader + PVH entry note
src/pvh.zig        PVH direct boot: start_info, modules, orchestration
src/trace.zig      marker-file-gated device tracing
src/vt/            VT subsystem: vendored parser + Nether-authored screen grid
src/webconsole.zig read-only web console (renders the live grid to HTML)
src/fuzz.zig       always-on fuzz-smoke for the guest-facing parsers
src/main.zig       thin binary wrapper over the core
docs/              thesis · design · roadmap · decisions · bringup-notes
docs/references/   ghostty-patterns (embeddable-core / concurrency inspiration)
```

## Toolchain

Targets **Zig 0.16.0 stable**, and also builds clean on recent 0.16 dev
nightlies (verified on `0.16.0-dev.2135`) - the std-API churn that used to break
nightlies (notably `std.atomic.Mutex`, which moved/disappeared) has been removed
from the codebase: the per-device lock is now a plain `std.atomic.Value` spinlock
(`src/lock.zig`). Pinning `zig` to a 0.16.0 stable install is still recommended for
reproducibility. See [`docs/bringup-notes.md`](docs/bringup-notes.md).
