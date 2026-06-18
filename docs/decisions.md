# Nether — Open Decisions

Decisions that shape the architecture and are cheaper to settle now than to
retrofit. Each has a recommendation; mark them RESOLVED as they're locked.

---

## D1 — OVMF coupling: fw_cfg vs forked firmware

**Status:** open · **Recommendation:** fw_cfg (option a)

Stock OVMF does not build its own ACPI for a QEMU-class machine. The tables come
from the VMM over **fw_cfg** plus the **ACPI linker/loader** protocol (a command
script OVMF runs to allocate, pointer-patch, and checksum tables in guest RAM).
Memory size, hotplug regions, SMBIOS, and boot order ride the same channel.

- **(a) Implement QEMU fw_cfg + linker-loader.** More work up front; in return
  you ride the entire OVMF/edk2 ecosystem unmodified, forever.
- **(b) Fork OVMF to discover the platform another way.** A tarpit — a firmware
  fork maintained against a moving upstream.

Pick (a). It's the difference between Phase 2 being a milestone and being a
maintenance liability. fw_cfg is therefore part of the firmware floor, not an
optional extra.

## D2 — Which devices go out-of-process

**Status:** open · **Recommendation:** per-device split below

The datapath is zero-alloc and in-process *by default*, but high-risk or
high-throughput devices are better offloaded. vhost/vhost-user moves the
datapath out of Nether's address space — which means the in-process zero-alloc
loop never runs for those devices, and (the point) the temporal-safety/fuzzing
burden doesn't cover them.

- **In-process, zero-alloc, fuzzed:** rng, balloon, console, vsock. Small
  parsers, low risk, worth owning.
- **Out-of-process from day one:** net (vhost-net/vhost-user), fs
  (virtiofsd/vhost-user), gpu (see D4).
- **block:** start in-process for Phase 3 simplicity; revisit vhost-user later.

## D3 — Config-plane concurrency

**Status:** open · **Recommendation:** per-device lock, shard later if needed

vCPU threads service MMIO/PIO exits that *write device state* (PCI config, MSI-X
tables, virtio config registers) while the I/O thread processes virtqueues
against the same state. That's shared mutable state across threads — QEMU's
big-lock problem in miniature. The zero-alloc datapath claim is about the queue
ring, not this.

Decide the discipline before the second device exists: a per-device lock taken on
config access and on queue processing is the simplest correct option; a coarse
machine lock is easier still but a known scaling ceiling. Either way, name it and
hold the line — retrofitting locking onto a racy device model is misery.

## D4 — virtio-gpu scope

**Status:** open · **Recommendation:** 2D-only for core, or cut to a spike

virtio-gpu with 3D/virgl is a host-side GL/Vulkan command parser fed
attacker-controlled buffers — historically a CVE fountain and bigger than the
other seven devices combined. It does not belong in a casual device list for a
security-posture-conscious VMM.

Options, in order of preference:
1. **2D dumb-framebuffer only** in core; no virgl.
2. **Fully out-of-process** behind a rutabaga-style boundary (crosvm model) if 3D
   is wanted.
3. **Cut from core**, treat 3D as a separate research spike.

Whatever the choice, it is explicit and not riding in on `rng`'s coattails.

## D5 — Test harness

**Status:** open · **Recommendation:** kvm-unit-tests + serial golden + fuzz

A VMM is the worst place to have no test story. Three layers, stood up early:

- **kvm-unit-tests** as the Phase-1.5 inner loop. It boots tiny bare-metal
  kernels that exercise exactly Nether's surfaces — APIC, IOAPIC routing, PCI,
  MSI, PM timer — and reports pass/fail over serial. Effectively a conformance
  suite for the thing being built; catches irqchip/routing bugs before any real
  guest would.
- **Serial golden-output tests**: a minimal initramfs that prints a banner and
  powers off via the PM block; assert on the serial log. Sub-second, CI-friendly.
- **Fuzzing**: a Zig fuzz target over raw descriptor-chain buffers feeding each
  in-process virtqueue/config parser — built the moment that parser exists, not
  at Phase 6.

## D7 — KVM bindings: hand-rolled vs @cImport

**Status:** RESOLVED (provisional) → hand-rolled for now

The design calls for `@cImport("linux/kvm.h")`. But `kvm.h` is a kernel *uapi*
header, not bundled with Zig, so `@cImport` only resolves on a Linux host with
kernel headers installed — it breaks `zig build` when cross-compiling from a
non-Linux dev host (this repo is driven from macOS). Phase 0 therefore uses
hand-rolled `extern struct` layouts plus comptime-derived ioctl numbers
(`src/kvm.zig`), validated against KVM's published ABI in unit tests.

This is reversible. Revisit once the dev/CI host is reliably Linux: either keep
hand-rolled (a stable uapi; rust-vmm-style hand maintenance is viable and keeps
cross-compute trivial) or switch to `@cImport` behind a build option. The tests
in `src/kvm.zig` are the safety net for either path.

## D6 — irqchip model

**Status:** RESOLVED → split irqchip

`KVM_CAP_SPLIT_IRQCHIP`: LAPIC in kernel, IOAPIC/PIC in userspace. Matches
firecracker/cloud-hypervisor, gives clean MSI routing via `KVM_SET_GSI_ROUTING` +
irqfd, and keeps the modern-only design honest. Full in-kernel irqchip is the
more legacy-flavored path; not chosen.
