# Nether - Docs

A type-2 KVM-backed VMM in Zig. Modern guests only, no legacy hardware. The
isolation substrate of a *govern · isolate · meter · edge* platform.

- **[thesis.md](thesis.md)** - why Nether exists: the platform thesis, where
  Nether fits (the isolation layer), the wedge, and what the thesis demands of
  the design. **Read this first.**
- **[design.md](design.md)** - what Nether is, scope, the no-legacy cut line,
  Zig approach, security posture, prior art.
- **[roadmap.md](roadmap.md)** - phased plan. Win condition is Phase 3 (boots
  Linux over virtio-pci with MSI-X); the platform track layers on after.
- **[decisions.md](decisions.md)** - open architectural decisions worth settling
  before they calcify (OVMF/fw_cfg coupling, device out-of-process split,
  config-plane locking, virtio-gpu scope, test harness, irqchip model).
- **[running-on-kvm.md](running-on-kvm.md)** - turnkey path from a fresh KVM host
  to a live boot: verify /dev/kvm, install Zig, run tests + the smoke test, then
  build a PVH kernel + initramfs, boot Linux, and attach a virtio-blk disk.
- **[bringup-notes.md](bringup-notes.md)** - the hard-won, hardware-only gotchas
  found taking Nether from a `KVM_RUN` skeleton to an interactive Linux shell
  (segment limits, CPUID, PVH magic, the serial stall, IOAPIC, ACPI, the
  toolchain pin). Read before debugging a live boot.
- **[references/ghostty-patterns.md](references/ghostty-patterns.md)** - Ghostty
  as an architecture reference: patterns borrowed for the embeddable core,
  concurrency model, and a future server-side console.

## Start here

The thesis ([thesis.md](thesis.md)) says *why*. **Nether PVH-boots Linux 6.12 to
an interactive shell with working virtio-blk read/write on a bare-metal KVM
host** (verified); see [roadmap.md](roadmap.md) for what is done and what is next.
To reproduce a live boot, follow [running-on-kvm.md](running-on-kvm.md) with
[bringup-notes.md](bringup-notes.md) on hand.
