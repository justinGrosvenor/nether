# Nether - Design

A type-2 virtual machine monitor written in Zig. Modern guests only, no legacy
hardware. Runs in the layer below the guest, hence the name.

> Nether is the **isolation layer** of a *govern · isolate · meter · edge*
> platform - see [thesis.md](thesis.md) for the why. The thesis pulls the edge
> path (embeddable core, vsock spine, snapshot-fork, PVH fast boot) forward of
> the general-VMM path; the design below is the full envelope, the roadmap
> sequences it.

## Design point

Past Firecracker, short of QEMU. The same envelope as Cloud Hypervisor:
hardware-assisted virtualization only, paravirtual and modern-standard
interfaces, arbitrary modern guests including Windows, and a deliberate refusal
to emulate old hardware. No binary translation, no CPU emulation. KVM does the
privileged work; Nether is a userspace VMM driving it over ioctls.

## Backend and targets

- KVM (Linux). Hardware virtualization required: VT-x/AMD-V, EPT/NPT.
- x86-64 first. aarch64 later (zvm proves the PCI path there).
- Type-2 only. Not building a vmkernel or a driver stack.

## In scope

- PCIe: ECAM host bridge, virtio-pci, MSI-X.
- ACPI: FADT, MADT, MCFG, SRAT/SLIT, DSDT/SSDT including hotplug AML.
- UEFI via OVMF. Boot disk images, not hand-loaded kernels.
- virtio-pci device set: block, net, rng, balloon, vsock, console, fs, gpu.
- VFIO passthrough (NVMe, NIC, GPU) through the IOMMU. Optional virtio-iommu.
- vhost / vhost-user backend offload.
- SMP, CPU and memory hotplug, NUMA.
- Snapshot/restore, then live migration.

## Irreducible firmware floor

OVMF expects a minimum platform, so these exist despite the no-legacy stance:
16550 serial, RTC, ACPI PM block for reset and shutdown, in-kernel
LAPIC/IOAPIC via the KVM irqchip, kvmclock/TSC.

> Audit note: the *true* floor is whatever stock OVMF probes at boot. Expect it
> to also include **fw_cfg** (tables/memory/SMBIOS transport - see
> [decisions](decisions.md#d1-ovmf-coupling-fw_cfg-vs-forked-firmware)), the
> **0xCF9 reset port** (OVMF's ResetSystem path), and an OVMF **debug port**
> (~0x402). Derive the list from the OVMF source, not from a hang.

## Out of scope

The no-old-hardware cut line:

- Legacy BIOS / SeaBIOS, real mode, binary translation.
- IDE/ATA, e1000, rtl8139, floppy, ISA cruft, VGA text mode, Bochs VBE.
- i440FX/PIIX chipset emulation.
- 32-bit guest accommodation.
- Anything requiring CPU instruction emulation.

## Zig approach

- **Hand-rolled KVM ABI** (`extern struct` layouts + comptime-derived ioctl
  numbers, validated in unit tests), not `@cImport`. `kvm.h` is a kernel uapi
  header not bundled with Zig, so `@cImport` breaks cross-compiling from a non
  Linux dev host (this repo is driven from macOS). Reversible once dev/CI is
  reliably Linux; see [decisions](decisions.md#d7-kvm-bindings-hand-rolled-vs-cimport).
  VFIO bindings will face the same choice.
- `extern struct`/`extern union` for `kvm_run` and device register layouts.
- comptime generation of fixed binary structures: static ACPI tables, PCI config
  space, virtio config, ioctl numbers, the memory map.
- Zero-alloc hot path for virtqueue processing and MMIO exit handling. Explicit
  allocators throughout, Swerver discipline.
- Threading: one host thread per vCPU, each in its own `KVM_RUN` loop, plus a
  host I/O thread (today a blocking stdin reader feeding the serial RX; the
  target is one epoll/io_uring loop over eventfds: irqfd, ioeventfd, stdin,
  vsock). No async runtime.
- **Embeddable core as a compile-time boundary.** Production is swerver importing
  nether in one binary; the thin `main.zig` wrapper is for dev/bringup only. The
  host is selected behind a seam, not referenced by the core; the core
  is planned to export both a Zig API and a C ABI from one build. See the apprt
  and one-library-two-ABIs patterns in
  [references/ghostty-patterns.md](references/ghostty-patterns.md).

> The datapath is zero-alloc and lock-free per the above. The **config plane is
> not** - vCPU threads write device state (PCI config, MSI-X tables, virtio
> config) on MMIO/PIO exits while a host thread touches the same state. The
> discipline is **resolved** ([decisions D3](decisions.md#d3-config-plane-concurrency)):
> a per-device lock, one global lock order, and no lock held across a syscall.
> First instances are the serial RX FIFO and the IOAPIC redirection table. The
> scaling path (message-passing mailboxes, an event-loop I/O thread) is in
> [references/ghostty-patterns.md](references/ghostty-patterns.md).

## Security posture

Nether is a guest-to-host trust boundary parsing attacker-controlled data on the
virtqueue and device paths. Zig gives bounds checks under ReleaseSafe but not
temporal safety. Mitigations: ReleaseSafe on all guest-facing parsing, fuzz the
virtqueue and device-config parsers, push device backends out of process via
vhost-user where practical.

> Per-device boundary, not a blanket: small in-process parsers (rng, balloon,
> console, vsock) are owned and fuzzed; large/high-risk surfaces (net, fs, and
> especially **gpu**) go out-of-process. virtio-gpu with 3D/virgl is a
> host-side GL command parser and the single biggest attack surface in the
> device set - scope it deliberately, see
> [decisions](decisions.md#d4-virtio-gpu-scope).

## Prior art

- **zvm** (tw4452852): virtqueue, virtio-pci-modern, MSI-X, vhost-net already in
  Zig. Closest reference. Crib heavily.
- **Ymir** (Writing Hypervisor in Zig, smallkirby): VT-x/VMCS/EPT internals and
  UEFI handling, but type-1, so architecture reference only.
- **zvisor** (b0bleet): minimal KVM ioctl loop and memory setup skeleton.
- **cloud-hypervisor + rust-vmm**: architecture reference for the modern-only
  envelope. ACPI/PCI/VFIO design decisions.
- **Ghostty** (terminal emulator in Zig): not VMM prior art, but the reference
  for an embeddable Zig core decoupled from its host and exposed to both Zig and C
  consumers. Patterns borrowed in
  [references/ghostty-patterns.md](references/ghostty-patterns.md). Its terminal
  core is also the candidate engine for a future server-side console.

## Naming

Underworld theme. The bootloader ferries the guest across (Charon/Styx). Device
backends are shades. The hypercall interface is where the guest reaches up out of
the underworld to bargain.
