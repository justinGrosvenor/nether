# Nether design

Nether is a type-2 VMM in Zig. Hardware virtualization executes guest CPUs;
Nether provides guest memory, devices, boot setup, and a control interface.

This page distinguishes the current design from the broader VMM roadmap.
[Stack status](stack.md) is the current capability and verification reference.

## Current design point

The supported host/backend pairs are macOS/aarch64 with Hypervisor.framework and
Linux/x86-64 with KVM. ARM Linux loads directly from an Image and initramfs;
x86 Linux uses PVH. There is no Linux/aarch64 backend or software CPU emulator.

The backend is selected at compile time. `src/root.zig` exports shared types,
while `src/main.zig` still contains substantial backend-specific boot, restore,
and process wiring. The Swerver stack runs this executable in separate VM
processes under nether-supervisor.

Both backends have Linux boot, SMP, shared virtio devices, control sockets,
metering, and snapshot/COW restore. Additional HVF functionality includes the
2D GPU path, storage transforms, and midstream resume demonstrations. The
backends are not fully interchangeable.

## Device and state boundaries

The current devices run inside the VMM process. KVM uses a split interrupt
controller: LAPIC in the kernel, IOAPIC/PIC handling in userspace. HVF uses its
ARM interrupt and timer implementation, with PL011 serial and PL031 RTC support.

The vsock protocol engine keeps serializable connection and credit state
separate from host socket descriptors. This makes guest-channel restoration
possible, while external connections still need a surviving relay and explicit
reconnection logic.

Snapshots capture selected CPU/device state and RAM. RAM is mapped privately
from the base on restore. File-backed persistent disks and remote services
remain external state. See [forking](forking.md).

## Zig and concurrency

The build has no external Zig package dependencies and targets Zig 0.16.0.
KVM ABI bindings are handwritten with layout tests, enabling cross-compilation.
The code uses explicit allocators, fixed-capacity structures where appropriate,
and compile-time tables for hardware layouts.

Guest execution uses vCPU threads alongside host I/O and control threads.
Device and bus locks protect shared state; the whole datapath is not lock-free.
The current executable also has process-global state and detached workers, so
a clean multi-VM library lifecycle requires further work.

## Future envelope

The following are design goals, not current supported features:

- Single-process Swerver embedding with event-loop integration and a stable C ABI.
- UEFI/OVMF and Windows guests.
- Additional devices and offload, including balloon/fs and vhost-user.
- VFIO/IOMMU passthrough, CPU/memory hotplug, and NUMA.
- Live migration and multi-host orchestration.
- Out-of-process handling for larger device surfaces; 3D GPU is outside core scope.

The built-in x86 real-mode smoke guest is a substrate test, not support for
legacy operating systems. Linux direct boot remains the implemented guest path.

## Security and design history

Bounds checks, device validation, and fuzz smoke support the hostile-guest
security goal; they do not establish complete memory safety or availability.
The [security posture](security.md) and repository policy describe the limits.

[Decisions](decisions.md) retains the reasoning behind backend bindings,
interrupt routing, device concurrency, and GPU scope.
[Roadmap](roadmap.md) retains the development milestones and future envelope.
The internal reference notes record prior-art patterns; they are not evidence
that every proposed pattern is already implemented.
