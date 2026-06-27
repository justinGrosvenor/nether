# Nether source architecture

How `src/` is organized after the flat-to-domains reorg, so the layout is a written
contract and new files land in the right place. This is the *map of the code*; the
*why* (the platform thesis) is in [thesis.md](thesis.md), the *what's-built* is in
[roadmap.md](roadmap.md).

## Domain tree

```
src/
  root.zig    the library root - the public API surface (nether.*); what main and
              embedders import. Re-exports the types each domain offers.
  main.zig    the thin binary: per-OS boot orchestration (linuxMain / macBootLinux)
              + the watchdogs. The one place that wires the domains together.
  fuzz.zig    always-on fuzz-smoke over the guest-facing parsers (vt, virtq, vsock, net).

  common/     shared kernel - leaf utilities with no domain deps.
              lock trace power hvtypes hostutil conf
  mem/        guest memory map (single source of truth for the address space).
              memmap memmap_arm
  hv/         the hypervisor seam - the "isolate" core. Comptime backend by host OS.
              backend vm  kvm kvm_backend  hvf hvf_backend  irqchip ioapic  smp
  chipset/    the firmware floor / platform devices + the MMIO/PIO bus.
              io(the bus) pci serial pl011 pm rtc fw_cfg acpi(+dsdt.aml/.asl) reset
  virtio/     virtio-pci transport + the device leaves.
              virtio virtq  virtio_net virtio_console virtio_blk virtio_gpu
              virtio_vsock virtio_rng virtio_mmio
  net/        user-mode networking (the in-VMM NAT + egress firewall).
              slirp
  boot/       kernel load.
              pvh elf dtb
  agent/      the agent control plane (the platform layer on top of the VMM).
              control audit(journal) render webconsole snapshot armdev
  vt/         vendored VT parser + the Nether screen grid (terminal model).
              Parser Screen osc parse_table
```

## Layering (dependency direction)

Bottom-up; higher layers depend on lower, not the reverse:

1. **common/** - depended on by everything, depends on nothing (std/builtin only).
2. **mem/** - leaf address-space tables.
3. **hv/ + chipset/** - the *machine*, co-designed and mutually dependent: the bus
   (`chipset/io`) and interrupt routing (`hv/ioapic`, `hv/irqchip`) reference each
   other, and `chipset/serial` raises IRQs through `hv/ioapic` while `hv/kvm_backend`
   drives the bus. Treat these two as one layer.
4. **virtio/** - rides the bus (`chipset/io`, `chipset/pci`) + common.
5. **boot/** - `pvh` reads `chipset/acpi`, `mem/`, `hv/vm`.
6. **net/** - common + `agent/audit` (the journal it mirrors into).
7. **agent/** - the control plane; reaches the lower layers mostly through the
   `nether.*` namespace (`root.zig`) plus a few direct `hv/` calls.

`root.zig` is the namespace that ties it together: most files import each other
*directly* by relative path, but the cross-cutting types (`nether.Slirp`,
`nether.Power`, `nether.VsockDev`, ...) are reached via `@import("root.zig")`.

## The hypervisor seam (hv/)

The "isolate" core is a hard **compile-time** seam, not a runtime vtable. `backend.zig`
selects `kvm_backend.zig` on Linux (x86-64) and `hvf_backend.zig` on macOS (aarch64)
via `builtin.os.tag`; `vm.zig` is the hypervisor-agnostic wrapper (guest-RAM region
table + accessors); shared leaf types live in `common/hvtypes.zig`. The host OS fixes
the guest arch, and the two are never mixed in one binary. See
[decisions.md](decisions.md) D9.

HVF/aarch64 is the *lead* backend (where the full platform layer + SMP + snapshot were
built and live-proven). KVM/x86 is the *reference* backend: the platform layer is
wired there too and run-verified for control/vsock/watchdogs; it still trails on
virtio-net, SMP, snapshot, and GPU — see [linux-platform-port.md](linux-platform-port.md).

## Conventions (read before moving or adding a file)

- **Relative imports.** Zig `@import` (and `@embedFile`) resolve **relative to the
  importing file's directory**. Moving a file rewrites every relative path to/from it
  - the compiler verifies each, but it is real churn.
- **Cross-domain imports use `../<dir>/<file>.zig`.** This form resolves correctly
  even for a same-dir sibling (from `src/hv/`, `../hv/kvm.zig` == `src/hv/kvm.zig`),
  so there is no special case for same-domain vs cross-domain references.
- **Co-locate embedded data with its consumer.** `@embedFile` is relative too -
  `chipset/acpi.zig` embeds `chipset/dsdt.aml`. Don't separate them.
- **New file -> pick the layer it belongs to**, not where it's used from. A new
  virtio device goes in `virtio/`; a new control command in `agent/control.zig`; a new
  shared primitive in `common/`. If it's wired into both boot paths, it's likely
  `agent/` (platform) or `chipset/`/`hv/` (machine), not `main.zig`.
- **Expose it through `root.zig`** if other domains need it by namespace; keep it a
  direct relative import if only its own layer uses it.
- **Keep all three targets green** on every change:
  ```
  DEVELOPER_DIR=/Library/Developer/CommandLineTools zig test -target aarch64-macos src/root.zig
  DEVELOPER_DIR=/Library/Developer/CommandLineTools zig build -Dtarget=x86_64-linux
  ```
  then a native build + codesign before running on HVF (see SESSION-HANDOFF.md).

## Known follow-ups

- The `virtio_` filename prefix is redundant under `virtio/` (`virtio/virtio_net.zig`);
  dropping it is a trivial optional rename pass.
- `main.zig` still holds both boot orchestrations; splitting `boot/linux_main.zig` +
  `boot/mac_main.zig` is a later option. The shared platform init that the Linux port
  needs (`linux-platform-port.md` #3) would land as `agent/platform.zig`.
