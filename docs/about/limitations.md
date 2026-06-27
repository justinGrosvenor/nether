# Limitations

Honest scope notes for the current tree. These are intentional cuts and sequencing choices, not a backlog of unknown bugs.

## Backends are asymmetric

| Track | Maturity |
| --- | --- |
| **HVF / aarch64** | Platform layer live: Linux boot, virtio (blk/net/vsock/gpu), snapshot-fork, control plane, govern, observe, meter, SMP |
| **KVM / x86-64** | PVH Linux boot, virtio-blk, IOAPIC; platform layer wired and **run-verified on metal** for control plane, vsock, metering, watchdogs, and slirp (compile path). Remaining gaps: virtio-net guest interface, SMP AP boot, snapshot/restore, GPU |

See [Linux platform port](../linux-platform-port.md) for the KVM parity checklist and box-session results.

## Snapshot / restore

Snapshot save, rewind demo, and COW restore (`nether-restore` / `restore_from=`) are **HVF-only** today. KVM snapshot work is planned (`KVM_GET/SET_*` vCPU state + dirty pages) but not implemented.

## Not a general-purpose VMM (yet)

- **OVMF / UEFI** is deferred. The edge path is **PVH direct boot**, not full firmware emulation.
- **Windows guests** are future scope (Phase 4+).
- **Live migration** and **VFIO passthrough** are roadmap items, not shipping.
- **3D virtio-gpu / virgl** is explicitly out of core. 2D framebuffer only; 3D would be out-of-process.

## Embedding

The shipping artifact is one swerver binary with embedded nether. The integration
contract (vsock spine, per-VM-per-worker, eventfd registration into `IoRuntime`) is
designed but not fully wired yet. The standalone `nether` executable remains for
dev and bringup only.

## API stability

The library root (`src/root.zig`) and control protocol may change before 1.0. Downstream embedders should pin commits.

## Platform

nether is the **isolate + govern** layer inside the swerver binary. It does not own
routing, TLS, or billing — those stay in swerver and x402 above the embed boundary.

## Roadmap

Phases, done-lines, and the platform track are in [Roadmap](../roadmap.md). Architectural forks are recorded in [Decisions](../decisions.md).