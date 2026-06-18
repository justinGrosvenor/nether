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
  build a PVH kernel + initramfs and boot Linux.

## Start here

The thesis ([thesis.md](thesis.md)) says *why*. The Phase 1.5 substrate and the
PVH boot path are built; the next step is a live boot on a KVM host (see
[running-on-kvm.md](running-on-kvm.md)) and then virtio-blk. See
[roadmap.md](roadmap.md).
