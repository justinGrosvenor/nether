# Nether - Roadmap

**Status (verified on a bare-metal KVM host):** the substrate runs live, Nether
**PVH-boots Linux 6.12 to an interactive shell**, the userspace IOAPIC routes
serial IRQ4 (console no longer stalls at 16 bytes), and **virtio-blk reads and
writes work end to end** (the guest enumerates the device over the ACPI PCIe host
bridge, claims its BAR, and the kernel reads/writes `/dev/vda` with MSI-X
completions, writes landing on the host image). Built and unit-tested offline,
awaiting live verification: **continuous interactive stdin** via a host I/O
thread that feeds the serial RX and raises IRQ4 so an idle shell still receives
input (the first concrete [D3](decisions.md) per-device-lock instance);
**virtio-vsock** (the swerver<->guest channel); and **virtio-net** (a tap-backed
NIC), which completes the Phase 3 datapath device set (block + net + MSI-X) - so
the win condition is now gated on a live boot of a networked image rather than on
any missing device. See [decisions.md](decisions.md) D8 for the PVH gotchas, D6
for the irqchip/IOAPIC, and D3 for the concurrency model.

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
  The pure protocol engine is in-tree (`src/virtio_vsock.zig`): the 44-byte
  header codec, the per-connection state machine (REQUEST/RESPONSE/RW/SHUTDOWN/
  RST and credit), and credit-based flow control, with a fixed-pool connection
  table and outbound staging ring (snapshot-friendly by construction) and a
  host-facing event/`send`/`connect`/`close` API decoupled from the transport.
  The device wiring is in too (`VsockDev`): a `virtio.Backend` over three
  virtqueues (RX/TX/event) that copies guest TX packets into the engine and
  drains staged output back onto the guest's RX buffers, carrying the first
  two-threaded D3 per-device lock (vCPU-thread kicks vs host-thread `host*`
  calls; the lock is released before the MSI signal, matching serial/IOAPIC).
  It is wired into `main.zig` behind a `nether-vsock` marker as PCI 0:2.0 with an
  echo exerciser on port 1234. Unit- and fuzz-tested offline (the guest's TX
  packets are attacker-controlled); live boot verification and the real
  swerver-side listener are the remaining steps.
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
  tests. The grid handles the alternate screen and scroll regions, so full-screen
  TUIs (vim/less/htop) render correctly, and an **interactive web console** is
  wired (`src/webconsole.zig`: the server renders the live grid to HTML, a polling
  page displays it, and key presses POST to `/input` which feeds the serial RX;
  opt-in via a `nether-web` marker, port 9000). The console subsystem is
  feature-complete; only the small DECOM / wide-character grid bits remain. See
  [references/ghostty-patterns.md](references/ghostty-patterns.md) (2, 5) and
  [decisions.md](decisions.md) D5.
- **PVH / direct-boot fast path** beside OVMF. Linux-only edge guests boot via
  PVH (fast, no UEFI); OVMF stays for general/Windows guests. Slots alongside
  Phase 2-3 rather than replacing them.
- **Per-VM-per-worker ownership** as the concurrency model (see
  [decisions.md D3](decisions.md)) - one swerver worker owns one guest's device
  state, containing the vCPU/I-O race.

## aarch64 + Apple HVF (active)

Promoted from "later": the dev host is Apple Silicon, where Hypervisor.framework
runs aarch64 guests, so an HVF backend turns the Mac itself into a live KVM-class
host (no remote box) - and aarch64 is a real production target (Graviton, ARM
servers), not throwaway. This is the deferred aarch64 platform pulled forward,
done as a second hypervisor backend behind the seam.

The build-out arc (offline-first chunks):

1. **Backend seam (done).** `vm.zig` is now a hypervisor-agnostic wrapper (guest
   memory + region table + accessors); the hypervisor work (region mapping, IRQ
   setup, vCPU create, the run loop, boot entry) is a backend selected at
   comptime by host OS - `kvm_backend.zig` (Linux/x86-64) and `hvf_backend.zig`
   (macOS/aarch64), chosen in `backend.zig`. KVM is the full impl; HVF is a
   compiling scaffold (every op returns Unimplemented) so the macOS build and the
   offline test build are green today. See [decisions.md](decisions.md) D9.
2. **HVF skeleton (done).** `hvf.zig` (hand-rolled framework bindings) +
   `hvf_backend.zig`: `hv_vm_create` + `hv_vm_map` (guest RAM), `hv_vcpu_create`
   and a run loop that decodes data-abort (MMIO) exits to the device Bus and
   steps the PC, plus an aarch64 boot entry (PC + PSTATE). A hand-assembled
   aarch64 blob prints over an MMIO UART and powers off via a sentinel - first
   light on the Mac. build.zig links Hypervisor.framework on macOS; the binary is
   codesigned with the `com.apple.security.hypervisor` entitlement (ad-hoc for
   local dev). See [running-on-hvf.md](running-on-hvf.md).
3. **aarch64 substrate (in progress).** Done: **PSCI** power firmware (the run
   loop decodes `hvc` exits - SYSTEM_OFF/RESET become power requests, the arm64
   analog of the ACPI PM block) and a real **PL011 UART** (`pl011.zig`: DR/FR
   plus the AMBA PrimeCell ID registers so Linux's driver binds; TX to a host
   sink, an RX ring for host input, offline-tested). Remaining: the framework GIC
   (`hv_gic`, the in-kernel LAPIC analog), the ARM generic timer (delivered via
   the GIC), and a full aarch64 memory map - these are exercised by a real OS, so
   they land with step 4.
4. **aarch64 Linux boot (DONE).** An arm64 Alpine kernel (6.12) **boots under HVF
   on Apple Silicon all the way to an interactive userspace shell.** The pieces:
   the **DTB generator** (`dtb.zig`), the aarch64 memory map (`memmap_arm.zig`),
   the framework **GICv3** (`hv_gic`: distributor + redistributor + MSI region),
   the **generic timer** (delivered via the GIC), **PSCI** (HVC), the **PL011**
   console, and the `Image` + `X0 = DTB` boot path (`macBootLinux`). The keystone
   was **MPIDR_EL1**: GICv3 affinity routing requires each vCPU's MPIDR set before
   the framework will associate (and MMIO-intercept) its redistributor - without
   it `hv_gic_get_redistributor_base` returns BAD_ARGUMENT and all redistributor
   registers fall through. The redistributor *region* is ~32 MiB (sized for max
   vCPUs), placed clear of the UART/RAM, and its base is queried from the
   framework and written into the DTB. Trapped system-register accesses (EC 0x18)
   are emulated RAZ/WI. The kernel reaches `Run /init`, runs Alpine init, and
   drops to the initramfs recovery shell (it only lacks Alpine boot media). The
   shell is **interactive**: host stdin feeds the PL011 RX, which raises its SPI
   through the GIC (`hv_gic_set_spi`) so the guest tty reads it - typing a command
   runs it and prints back. With a real rootfs (the Alpine aarch64 minirootfs
   repacked as an initramfs with a tiny `/init`; recipe in
   [running-on-hvf.md](running-on-hvf.md)) it boots straight to a proper Alpine
   busybox shell as root. Next: virtio on aarch64 (step 5).
5. **virtio on aarch64 (foundation; BAR-assignment blocked).** Two transports
   exist behind the shared backends:
   - **virtio-mmio** (`virtio_mmio.zig`) - unit-tested and its DTB nodes parse
     (they appear under `/proc/device-tree`), but stock Alpine kernels build
     `VIRTIO_MMIO` as a module (not `=y`), so nothing binds. Kept as the clean
     path for a `CONFIG_VIRTIO_MMIO=y` kernel.
   - **virtio-pci** (the path stock kernels support): a generic-ECAM host bridge
     (`pci.zig` made ECAM-base-configurable) + a `pcie@...` DTB node (ranges,
     bus-range, 64-bit non-prefetchable MMIO window) + a window-wide dispatcher
     routing to the device's live BAR. **The virtio-rng device now enumerates**:
     it appears as `0000:00:01.0 [1af4:1044]` in the guest's PCI bus and sysfs,
     BAR sized and detected. The virtio BAR was switched to 64-bit
     non-prefetchable (pci-host-generic requires a non-pref window; harmless on
     x86).
   - **DTB now QEMU-equivalent and `dtc`-clean.** Installed `qemu`/`dtc`, dumped a
     real `-M virt` DTB, and diffed the `pcie` node against ours - which surfaced
     and fixed several real bugs: the GIC node was missing `#address-cells`/
     `#size-cells`/`ranges` (so an `interrupt-map` referencing it mis-parsed); the
     `interrupt-map` entries lacked the 2 parent-address cells the GIC's
     `#address-cells=2` requires; we had only one MMIO window where QEMU has both
     a 32-bit non-prefetchable and a 64-bit window (both now emitted and
     registered by the kernel as root-bus resources); and `bus-range` is now
     consistent with the 1-bus ECAM. The blob validates clean under `dtc`.
   - **Root cause isolated via trace-diff (still open).** Captured Nether's
     config-space accesses (trace marker) and QEMU's (`-trace pci_cfg_write`) for
     the same kernel + an equivalent DTB, and ran the kernel's PCI setup `dyndbg`:
       * Nether: the kernel sizes BAR0 (writes 0xffffffff, reads the mask, writes
         the type bits back) and then goes **straight to the virtio-pci probe** -
         no assignment write to BAR0, COMMAND register never enabled. The PCI
         setup debug shows scan -> "resource 4/5" -> "not claimed", with **no
         `pci_bus_assign_resources` pass at all**.
       * QEMU: after sizing, a second pass **assigns** (`@0x20<-0x400c @0x24<-0x80`
         -> BAR at 0x8000004000) and **enables** the device (`@0x4<-0x7` =
         MEM|IO|BUS_MASTER), then `/dev/hwrng` works.
     So Nether's `pci-host-generic` takes the **claim** path while QEMU's takes
     **assign** - the device tree and the config-space emulation are both correct
     (device enumerates, BAR sizes right); the difference is purely the kernel's
     claim-vs-assign decision for this bus. Ruled out (tested, no effect):
     prefetchable vs non-pref BAR/window, 32/64-bit windows, the I/O window
     (root-bus resources now match QEMU exactly), interrupt-map, GIC #address-cells,
     bus-range, pre-assign vs kernel-assign, `pci=realloc`, and
     `linux,pci-probe-only=0`.
   - **Kernel 6.12 source read (done) - and the contradiction.** Traced the full
     call graph: `pci-host-common.c` calls `of_pci_check_probe_only()` then
     `pci_host_probe()`, which claims first only if `bridge->preserve_config` and
     then *unconditionally* calls `pci_assign_unassigned_root_bus_resources()`
     ("if we didn't claim above, this will reassign everything").
     `bridge->preserve_config = pci_preserve_config()` = `pci_acpi_preserve_config`
     (false on a DT boot - no ACPI handle) OR `of_pci_preserve_config(pcie_node)`,
     which with `linux,pci-probe-only=<0>` (confirmed in the blob via dtc) returns
     false; `of_pci_check_probe_only` then clears the global `PCI_PROBE_ONLY`. So
     **by the source the assign pass should run and reassign our BAR** - yet
     setup-bus.c emits nothing for our device (no "assigned"/"no space") and the
     BAR is never written, while QEMU's kernel (same Image, equivalent DT boot)
     assigns and enables it. The source-level gates all say "assign" but the
     runtime takes the claim path: a contradiction that source-reading and
     guest-side tracing cannot resolve.
   - **One structural diff remains:** QEMU's node has `msi-map` -> a
     `arm,gic-v2m-frame` msi-controller; ours has none (the framework GIC's MSI
     isn't described to the guest). Unproven whether it diverts resource
     assignment, but it's the next lever. **Next:** (a) model the GIC MSI in the
     DTB (a GICv3 ITS or v2m frame) + wire `hv_gic_send_msi`, then retest
     assignment; or (b) use an instrumented/debuggable kernel (CONFIG_PCI_DEBUG
     build, or a kgdb / QEMU-gdb session) to watch the assign decision directly,
     since the stock kernel contradicts its own source here. The transport,
     datapath, and DTB are correct and reusable; only this last kernel-side assign
     gate stands between enumeration and a bound virtio-pci device.

The x86-64/KVM path stays the reference backend; its one remaining Phase 3 step
(a live networked boot) is independent of this track.
