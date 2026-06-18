# Nether — Docs

A type-2 KVM-backed VMM in Zig. Modern guests only, no legacy hardware. The
isolation substrate of a *govern · isolate · meter · edge* platform.

- **[thesis.md](thesis.md)** — why Nether exists: the platform thesis, where
  Nether fits (the isolation layer), the wedge, and what the thesis demands of
  the design. **Read this first.**
- **[design.md](design.md)** — what Nether is, scope, the no-legacy cut line,
  Zig approach, security posture, prior art.
- **[roadmap.md](roadmap.md)** — phased plan. Win condition is Phase 3 (boots
  Linux over virtio-pci with MSI-X); the platform track layers on after.
- **[decisions.md](decisions.md)** — open architectural decisions worth settling
  before they calcify (OVMF/fw_cfg coupling, device out-of-process split,
  config-plane locking, virtio-gpu scope, test harness, irqchip model).

## Start here

The thesis ([thesis.md](thesis.md)) says *why*. The next concrete step is Phase 0
— the `KVM_RUN` loop to serial-out (already scaffolded) — followed by the Phase
1.5 substrate, which is where the project actually gets hard. See
[roadmap.md](roadmap.md).
