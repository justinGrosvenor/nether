# Nether - Open Decisions

Decisions that shape the architecture and are cheaper to settle now than to
retrofit. Each has a recommendation; mark them RESOLVED as they're locked.

---

## D1 - OVMF coupling: fw_cfg vs forked firmware

**Status:** open, sequenced behind PVH · **Recommendation:** fw_cfg (option a)

For ephemeral agent guests the live path is **PVH direct-boot** (fast, no UEFI),
already working on both backends; OVMF stays for general/Windows guests and is
sequenced behind the platform track (roadmap Phase 2), not on the critical path. The
fw_cfg/linker-loader work below is what unlocks it when that phase comes up.

Stock OVMF does not build its own ACPI for a QEMU-class machine. The tables come
from the VMM over **fw_cfg** plus the **ACPI linker/loader** protocol (a command
script OVMF runs to allocate, pointer-patch, and checksum tables in guest RAM).
Memory size, hotplug regions, SMBIOS, and boot order ride the same channel.

- **(a) Implement QEMU fw_cfg + linker-loader.** More work up front; in return
  you ride the entire OVMF/edk2 ecosystem unmodified, forever.
- **(b) Fork OVMF to discover the platform another way.** A tarpit - a firmware
  fork maintained against a moving upstream.

Pick (a). It's the difference between Phase 2 being a milestone and being a
maintenance liability. fw_cfg is therefore part of the firmware floor, not an
optional extra.

In progress: `fw_cfg.zig` implements the traditional PIO interface (selector,
data, file directory); `acpi.zig` generates the fixed-placement table set
(RSDP/XSDT/FADT/FACS/MADT/MCFG/DSDT) with real checksums. Two pieces remain to
make stock OVMF consume them: the **ACPI linker/loader** (`etc/table-loader`
ROMFILE_ALLOC / ADD_POINTER / ADD_CHECKSUM commands) plus serving the table blob
and `etc/acpi/rsdp` over fw_cfg, and the **fw_cfg DMA** interface (optional;
OVMF falls back to PIO without it). The same `acpi.zig` output feeds the PVH
direct-boot path, where the RSDP address is handed to the kernel instead.

## D2 - Which devices go out-of-process

**Status:** open · **Recommendation:** per-device split below

The datapath is zero-alloc and in-process *by default*, but high-risk or
high-throughput devices are better offloaded. vhost/vhost-user moves the
datapath out of Nether's address space - which means the in-process zero-alloc
loop never runs for those devices, and (the point) the temporal-safety/fuzzing
burden doesn't cover them.

- **In-process, zero-alloc, fuzzed:** rng, balloon, console, vsock. Small
  parsers, low risk, worth owning.
- **Out-of-process from day one:** net (vhost-net/vhost-user), fs
  (virtiofsd/vhost-user), gpu (see D4).
- **block:** start in-process for Phase 3 simplicity; revisit vhost-user later.

## D3 - Config-plane concurrency

**Status:** RESOLVED → per-device lock, shard later if needed

vCPU threads service MMIO/PIO exits that *write device state* (PCI config, MSI-X
tables, virtio config registers) while the I/O thread processes virtqueues
against the same state. That's shared mutable state across threads - QEMU's
big-lock problem in miniature. The zero-alloc datapath claim is about the queue
ring, not this.

Decided: a **per-device lock** taken on config access and on queue processing. A
coarse machine lock is easier still but a known scaling ceiling. The discipline
is named, so it gets held as devices are added rather than retrofitted onto a
racy model.

First instances landed with the interactive-stdin I/O thread. The host stdin
thread feeds `Serial.pushRx` while the vCPU thread services serial register
exits, and the IOAPIC redirection table is read on `raise()` from both threads
while the guest programs it from the vCPU thread. Each device carries its own
`Lock` (`src/lock.zig`, now a plain `std.atomic.Value` spinlock - it dropped the
version-volatile `std.atomic.Mutex` so the tree builds on both 0.16.0 stable and
dev nightlies - since the critical sections are a few field writes). The rules
that keep it correct, to be repeated for every future device:

- **One lock order, globally:** serial -> ioapic. A device raising an IRQ
  releases its own lock first, then calls into the IOAPIC.
- **No lock held across a blocking or slow syscall:** the serial TX `write`, the
  IRQ `signalMsi`, and the raise itself all happen after the relevant unlock.

virtio-vsock (`VsockDev`) is the first *virtio* device to take the lock, and the
pattern repeats cleanly: the vCPU thread processes queue kicks (`onNotify`) while
the host thread stages output through the `host*` methods, both mutating the
engine and the RX/TX rings under the device's `Lock`. The MSI completion
(`interruptQueue`) is raised only after unlocking, as above. One vsock-specific
wrinkle is the engine's `on_event` callback: it fires from inside `engine.rx()`,
which only runs while the lock is held, so a handler must reply via the engine
directly rather than the locking `host*` API (the spin lock is non-recursive) -
documented as the VsockDev re-entrancy contract. The lock stays independent of
the serial -> ioapic order because vsock never nests with them.

The "shard later if needed" half has since landed too, driven by SMP. The global
bus lock came off the virtio hot path: the device registry is immutable after init,
so the bus lock now only guards lookup + simple self-locking devices, while each
virtio `Device` carries its own `dev_lock` (vCPU<->vCPU) and a separate `irq_lock`
(host<->vCPU interrupt state). The global order is now `dev_lock -> backend lock ->
irq_lock`, with backends releasing their lock before `interruptQueue`; a
50k-iteration concurrent test guards against deadlock/torn state. So concurrent vCPUs
run in different devices in parallel, and a notify's host I/O no longer holds a
global lock.

## D4 - virtio-gpu scope

**Status:** RESOLVED -> 2D dumb-framebuffer in core, no virgl (option 1, shipped)

`virtio_gpu.zig` implements exactly option 1: a minimal 2D virtio-gpu (device id 16)
over the existing virtio-pci transport - GET_DISPLAY_INFO / RESOURCE_CREATE_2D /
ATTACH_BACKING / SET_SCANOUT / TRANSFER_TO_HOST_2D / RESOURCE_FLUSH / UNREF, all
guest fields bounds-checked, no 3D/virgl host command parser. A stock Linux
`virtio_gpu` DRM driver binds it (`/dev/fb0`, `/dev/dri/card0`) and the framebuffer
is read live and emitted as a PPM (`__frame__`) with a tile-diff stream
(`__framediff__`). The CVE-fountain 3D path stays out of core; if 3D is ever wanted
it goes out-of-process behind a rutabaga-style boundary (option 2), not into core.

virtio-gpu with 3D/virgl is a host-side GL/Vulkan command parser fed
attacker-controlled buffers - historically a CVE fountain and bigger than the
other seven devices combined. It does not belong in a casual device list for a
security-posture-conscious VMM.

Options, in order of preference:
1. **2D dumb-framebuffer only** in core; no virgl.
2. **Fully out-of-process** behind a rutabaga-style boundary (crosvm model) if 3D
   is wanted.
3. **Cut from core**, treat 3D as a separate research spike.

Whatever the choice, it is explicit and not riding in on `rng`'s coattails.

## D5 - Test harness

**Status:** partial -> fuzz-smoke built; unit suite at 181 tests; kvm-unit-tests +
serial-golden layers still to stand up (not descoped)

A VMM is the worst place to have no test story. Three layers, stood up early:

- **kvm-unit-tests** as the Phase-1.5 inner loop. It boots tiny bare-metal
  kernels that exercise exactly Nether's surfaces - APIC, IOAPIC routing, PCI,
  MSI, PM timer - and reports pass/fail over serial. Effectively a conformance
  suite for the thing being built; catches irqchip/routing bugs before any real
  guest would.
- **Serial golden-output tests**: a minimal initramfs that prints a banner and
  powers off via the PM block; assert on the serial log. Sub-second, CI-friendly.
- **Fuzzing**: a Zig fuzz target over raw descriptor-chain buffers feeding each
  in-process virtqueue/config parser - built the moment that parser exists, not
  at Phase 6.

In progress: the fuzz-smoke layer is stood up (`src/fuzz.zig`), an always-on
deterministic smoke that runs with `zig build test`. It feeds thousands of
random byte streams to the two guest-facing parsers that exist today, the
vendored VT parser (`src/vt/`) and the virtqueue (`src/virtq.zig`), asserting
each always terminates in bounds and never panics. Pattern borrowed from the
jbsh harness (same toolchain, owned). A full AFL-style `zig build fuzz` target
and the kvm-unit-tests / serial-golden layers remain to build.

## D7 - KVM bindings: hand-rolled vs @cImport

**Status:** RESOLVED (provisional) → hand-rolled for now

The design calls for `@cImport("linux/kvm.h")`. But `kvm.h` is a kernel *uapi*
header, not bundled with Zig, so `@cImport` only resolves on a Linux host with
kernel headers installed - it breaks `zig build` when cross-compiling from a
non-Linux dev host (this repo is driven from macOS). Phase 0 therefore uses
hand-rolled `extern struct` layouts plus comptime-derived ioctl numbers
(`src/kvm.zig`), validated against KVM's published ABI in unit tests.

This is reversible. Revisit once the dev/CI host is reliably Linux: either keep
hand-rolled (a stable uapi; rust-vmm-style hand maintenance is viable and keeps
cross-compute trivial) or switch to `@cImport` behind a build option. The tests
in `src/kvm.zig` are the safety net for either path.

## D6 - irqchip model

**Status:** RESOLVED → split irqchip

`KVM_CAP_SPLIT_IRQCHIP`: LAPIC in kernel, IOAPIC/PIC in userspace. Matches
firecracker/cloud-hypervisor, gives clean MSI routing via `KVM_SET_GSI_ROUTING` +
irqfd, and keeps the modern-only design honest. Full in-kernel irqchip is the
more legacy-flavored path; not chosen.

Implemented in `irqchip.zig`: the cap is enabled (24 GSIs) before vCPU creation,
plus eventfd, irqfd, ioeventfd, and direct MSI injection (`KVM_SIGNAL_MSI`). The
cost of split is that the **userspace IOAPIC** (redirection table, EOI via
`KVM_EXIT_IOAPIC_EOI`) and `KVM_SET_GSI_ROUTING` for MSI-over-irqfd are now ours
to write. Deferred until a guest first programs the IOAPIC (OVMF) or virtio-pci
needs MSI-X routing; the run loop tolerates `EXIT_IOAPIC_EOI` as a no-op until
then.

Update: the **userspace IOAPIC is now built** (`ioapic.zig`). Without it the guest
read all-ones from 0xFEC00000 and disabled legacy IRQ routing, so serial (IRQ4)
interrupts never fired and the tty console stalled after 16 FIFO bytes. The
IOAPIC translates a redirection entry to an MSI on `raise(gsi)` and injects via
`signalMsi`; serial raises IRQ4 on THR-empty/RX-ready. **Live-verified** on bare
metal: the KVM guest boots to an interactive shell with serial IRQ4 firing and no
16-byte FIFO stall (see D8).

## D8 - PVH bring-up gotchas (resolved, verified on KVM)

Nether boots Linux 6.12 to a userspace shell via PVH on a bare-metal KVM host.
Four bugs sat between "kernel loads" and "Run /init", each only findable on real
hardware. Recorded so they are never re-debugged:

1. **Segment limit is byte-granular in the VMCS.** A flat 4 GiB segment needs
   `kvm_segment.limit = 0xFFFFFFFF`, not the 20-bit descriptor value `0xFFFFF`.
   With `0xFFFFF` the limit is literally 1 MiB; the kernel text at 16 MiB is past
   it, so the first instruction fetch #GPs into a triple fault. KVM does not
   re-expand the limit by the G bit.
2. **CPUID must be programmed.** `KVM_GET_SUPPORTED_CPUID` ->
   `KVM_SET_CPUID2` on the vCPU. Without it the guest sees no long-mode bit and
   the kernel's `EFER.LME` `wrmsr` #GPs.
3. **PVH magic is `0x336ec578`** (`XEN_HVM_START_MAGIC_VALUE`). A wrong value
   trips `xen_prepare_pvh`'s `BUG()` (`ud2` -> triple fault with no IDT).
4. **Unclaimed-access logging must be silent on the hot path.** A print per
   unclaimed PIO/MMIO drowns the serial console and starves the guest during PIT
   probing. Unclaimed reads float high (all-ones), writes drop, no logging.

What the minimal platform got right: our static ACPI parsed, the ACPI PM timer
carried TSC calibration (the kernel's PIT calibration fails and falls back to
PMTIMER, so no i8254 is needed for boot), and the absent userspace IOAPIC is
handled gracefully ("I/O APIC ... registers return all ones, skipping").

## D9 - Hypervisor backend seam (KVM + Apple HVF)

**Status:** RESOLVED -> comptime backend selected by host OS

The dev host is Apple Silicon, where Linux/KVM cannot run (no nested x86 virt,
and HVF only virtualizes the host arch). Rather than tether all live work to a
remote x86 box, Nether grows a second hypervisor backend: Apple
Hypervisor.framework, which makes the Mac a first-class live host - for aarch64
guests. That pulls the deferred aarch64 platform forward (justified: Graviton/ARM
servers make it a real production target), so the project becomes multi-arch,
multi-hypervisor.

Decided: a **hard compile-time seam**, not a runtime vtable - the backend follows
the host OS, which also fixes the guest arch, and the two are never mixed in one
binary. `vm.zig` is the hypervisor-agnostic wrapper (guest-RAM region table +
memory accessors, the parts that are pure host-slice work); everything
hypervisor-specific (region mapping, IRQ controller setup, vCPU create, the run
loop, boot entry) is a backend module. `backend.zig` selects `kvm_backend.zig` on
Linux and `hvf_backend.zig` on macOS via `builtin.os.tag`; shared leaf types
(`StopReason`, `Error`, LE marshalling) live in `hvtypes.zig` to avoid an import
cycle. This matches the embeddable-core thesis (a compile-time seam, not a
convention) and the ghostty apprt comptime-swap pattern in
[references/ghostty-patterns.md](references/ghostty-patterns.md) (1).

Consequences and rules going forward:
- The shared `Vm` exposes the backend handle as `vm.hv` so x86-only host code
  (IOAPIC, MSI) can reach the KVM `vm_fd`; aarch64 host wiring will reach its own
  backend fields. Arch-specific modules (PVH loader, IOAPIC) stay compiled but
  unused on the other backend; HVF keeps inert x86 boot-entry stubs so the shared
  `Vcpu` type and the PVH loader compile on macOS.
- KVM is the *reference* backend (x86, the original live-verified PVH boot), but
  HVF is now the *lead* backend in practice: it started as a compiling scaffold
  (every op `Unimplemented`) and has since filled in completely over the aarch64 arc
  - it is where SMP, snapshot/fork, the full control plane, and every platform pillar
  were built and live-proven. The x86/KVM side now trails and gets the platform layer
  ported back onto it (gated on an x86 host). Both targets stay green every commit:
  `zig build test` (native macOS, HVF path) and `zig build -Dtarget=x86_64-linux`
  (KVM path + binary).
