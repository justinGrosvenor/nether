# Nether - Roadmap

**Status (verified on a bare-metal KVM host):** the substrate runs live, Nether
**PVH-boots Linux 6.12 to an interactive shell**, the userspace IOAPIC routes
serial IRQ4 (console no longer stalls at 16 bytes), and **virtio-blk reads and
writes work end to end** (the guest enumerates the device over the ACPI PCIe host
bridge, claims its BAR, and the kernel reads/writes `/dev/vda` with MSI-X
completions, writes landing on the host image). Built and unit-tested offline,
awaiting live verification: **continuous interactive stdin** via a host I/O
thread that feeds the serial RX and raises IRQ4 so an idle shell still receives
input (the first concrete [D3](decisions.md) per-device-lock instance). See
[decisions.md](decisions.md) D8 for the PVH gotchas, D6 for the irqchip/IOAPIC,
and D3 for the concurrency model.

Re-cut from the original six-phase plan. Two changes from the first draft:

1. A **platform-substrate phase (1.5)** is pulled out of "OVMF boots." That line
   secretly depends on fw_cfg, a minimal static ACPI set, the exit dispatcher,
   and the firmware floor - none of which are OVMF itself.
2. **ACPI is split.** The minimal static tables move up to Phase 1.5 (Linux needs
   MCFG/MADT/FADT to boot over virtio-pci); the hard ACPI - SRAT/SLIT, per-CPU
   SSDT, hotplug AML - stays in Phases 4-5 where it belongs.

The win condition is **Phase 3**: a clean modern-only VMM that boots a Linux disk
image over virtio-block/net with MSI-X. Everything past it is bonus, and each
later phase is its own project measured in months.

---

## Phase 0 - KVM skeleton

VM, vCPU, memory regions, `KVM_RUN` loop, serial out.

- `KVM_CREATE_VM`, `KVM_CREATE_VCPU`, `mmap` of `kvm_run`.
- `KVM_SET_USER_MEMORY_REGION` for a flat region.
- The run loop: dispatch on `KVM_EXIT_IO` / `KVM_EXIT_MMIO` / `KVM_EXIT_HLT`.
- 16550 serial as the first device, enough to print from a hand-loaded stub.

**Done when:** a tiny code blob runs under `KVM_RUN` and prints over serial.

## Phase 1.5 - Platform substrate

The real first hard milestone. None of this is glamorous; all of it is load-bearing.

- **Guest memory map as single source of truth** - RAM split around the sub-4GB
  PCI hole (TOLUD), high RAM above 4GB, ECAM window, 32/64-bit MMIO windows,
  LAPIC `0xFEE00000`, IOAPIC `0xFEC00000`. One comptime table generates the KVM
  memory regions, the E820/fw_cfg view, MTRRs, and ACPI `_CRS`. (Drift here =
  guest corruption that looks like nothing.)
- **MMIO/PIO exit dispatcher** - device tree keyed by address range; the spine
  everything else hangs off.
- **Split irqchip** - `KVM_CAP_SPLIT_IRQCHIP` (LAPIC in kernel, IOAPIC/PIC in
  userspace); irqfd + ioeventfd plumbing on the I/O thread.
- **fw_cfg** - the DMA interface plus the ACPI linker/loader command stream, so
  stock OVMF can find tables/memory/SMBIOS. See
  [decisions D1](decisions.md#d1-ovmf-coupling-fw_cfg-vs-forked-firmware).
- **Firmware floor** - RTC, ACPI PM block, 0xCF9 reset, kvmclock/TSC.
- **Minimal static ACPI** (comptime) - RSDP, XSDT, FADT, MADT, MCFG, a minimal
  DSDT.
- **Test harness** - kvm-unit-tests as the inner loop (it exercises APIC/IOAPIC
  routing, PCI, MSI, PM timer and reports over serial); serial golden-output
  tests. See [decisions D5](decisions.md#d5-test-harness).

**Done when:** kvm-unit-tests' core APIC/PCI suites pass, and the substrate can
present a PCIe host bridge + the firmware floor to a guest.

## Phase 2 - OVMF boots

OVMF reaches the UEFI shell on top of the substrate.

- Map OVMF_CODE.fd / OVMF_VARS.fd.
- Verify OVMF consumes fw_cfg (memory, ACPI linker-loader) cleanly.
- Wire OVMF debug output (debug port) into the host log for triage.

**Done when:** OVMF reaches the UEFI shell with no hand-holding.

## Phase 3 - Boot Linux (WIN CONDITION)

virtio-pci block and net, MSI-X, boot a Linux disk image.

- virtio-pci-modern transport; virtqueue datapath (zero-alloc, in-process for
  block to start).
- MSI-X: table in BAR, intercepted writes → `KVM_SET_GSI_ROUTING` + irqfd.
- virtio-blk backed by a disk image; virtio-net (tap, or vhost-net early - see
  [decisions D2](decisions.md#d2-which-devices-go-out-of-process)).
- virtio-rng/console as warm-ups.

**Done when:** a stock Linux cloud image boots to a login prompt over
virtio-block/net with MSI-X interrupts.

## Phase 4 - Boot Windows

The difficulty cliff. Windows is a brutal ACPI conformance test.

- Full DSDT/SSDT, per-CPU objects, correct `_CRS`/`_PRT`.
- SMP.
- Whatever device conformance Windows demands that Linux forgave.

**Done when:** Windows boots and is stable.

## Phase 5 - Passthrough, hotplug, NUMA

- VFIO passthrough (NVMe, NIC, GPU) through the IOMMU; optional virtio-iommu.
- CPU and memory hotplug - **hotplug AML** (GPE blocks, `_EJ0`, `_STA`).
- SRAT/SLIT and NUMA topology.

## Phase 6 - Snapshot, then live migration

- **Snapshot/restore** - enumerate *all* architectural state to GET/SET: regs,
  sregs, all MSRs, xsave/xcrs, debugregs, lapic, mp_state, vcpu_events, and
  **kvmclock + TSC** (the time-corruption traps). Per-device serialization with a
  **version tag from day one**.
- **Live migration** - dirty-page tracking (`KVM_GET_DIRTY_LOG`), iterative
  pre-copy, device-state stream. The real boss; team-quarters of work elsewhere.

---

## Platform track (thesis-driven)

These are not a seventh phase - they are reprioritizations the
[thesis](thesis.md) imposes on the phases above, captured here so the edge
product shapes the core instead of being bolted on. The principle: **build the
edge path forward of the general-VMM path**, but never ahead of the Phase 3
done-line.

- **Embeddable core from Phase 0.** Library + thin binary, allocator injected,
  no process-global state, device I/O expressed as fds. Costs ~nothing now;
  enables swerver to host Nether later. (Already true of the Phase 0 scaffold.)
  Make the host boundary a hard *compile-time* seam (not a convention) and plan
  the core to export both a Zig API and a C ABI from one build. See the apprt and
  one-library-two-ABIs patterns in
  [references/ghostty-patterns.md](references/ghostty-patterns.md) (1, 2).
- **vsock promoted to the spine** (lands with the virtio work in Phase 3+).
  The swerver↔guest channel, integrated via swerver's park-and-resume pattern.
- **Snapshot-aware device models from Phase 3.** Don't ship a device whose state
  can't be serialized; snapshot-fork (boot once → clone per request) is the edge
  product, so the Phase 6 "snapshot" work is really a constraint applied early.
  Target fixed-size, pool-allocated, ref-countable, serializable-by-construction
  state; see the paged-storage pattern in
  [references/ghostty-patterns.md](references/ghostty-patterns.md) (6).
- **Concurrency model: per-device lock now, message-passing later.** D3 is
  resolved with per-device locks (first instances: serial RX, IOAPIC raise). The
  scaling path is a mailbox/SPSC-queue model and a libxev event-loop I/O thread;
  see [references/ghostty-patterns.md](references/ghostty-patterns.md) (3, 4),
  adopted when lock contention or a second host input source forces it.
- **Server-side console.** The VT engine exists in-tree (`src/vt/`): the
  vendored parser plus a Nether-authored screen grid (`Screen.zig`, with UTF-8),
  both fuzz-smoked, and the **console tee is wired** (the serial device mirrors
  guest output into a `Screen`, so the VMM holds a live render; dumped on exit
  under trace) with **scrollback** (a ring of evicted rows; the exit dump shows
  the full boot log). That unlocks console-state snapshots and grid-level golden
  tests. The grid now also handles the alternate screen and scroll regions, so
  full-screen TUIs (vim/less/htop) render correctly. Remaining: ship the grid to
  a frontend (web console); DECOM and wide-character width are the small bits
  left. See
  [references/ghostty-patterns.md](references/ghostty-patterns.md) (2, 5) and
  [decisions.md](decisions.md) D5.
- **PVH / direct-boot fast path** beside OVMF. Linux-only edge guests boot via
  PVH (fast, no UEFI); OVMF stays for general/Windows guests. Slots alongside
  Phase 2-3 rather than replacing them.
- **Per-VM-per-worker ownership** as the concurrency model (see
  [decisions.md D3](decisions.md)) - one swerver worker owns one guest's device
  state, containing the vCPU/I-O race.

## aarch64 (later)

GIC instead of APIC, device tree or ACPI, no fw_cfg. zvm proves the PCI path.
Deferred until x86-64 is solid.
