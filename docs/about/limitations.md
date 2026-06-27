# Limitations

Honest scope notes for the current tree. These are intentional cuts and sequencing choices, not a backlog of unknown bugs.

## Backends are asymmetric

| Track | Maturity |
| --- | --- |
| **HVF / aarch64** | Platform layer live: Linux boot, virtio, snapshot-fork, control plane, govern, observe, meter |
| **KVM / x86-64** | PVH Linux boot, virtio-blk, IOAPIC; platform layer port in progress |

See [Linux platform port](../linux-platform-port.md) for the KVM parity checklist.

## Not a general-purpose VMM (yet)

- **OVMF / UEFI** is deferred. The edge path is **PVH direct boot**, not full firmware emulation.
- **Windows guests** are future scope (Phase 4+).
- **Live migration** and **VFIO passthrough** are roadmap items, not shipping.
- **3D virtio-gpu / virgl** is explicitly out of core. 2D framebuffer only; 3D would be out-of-process.

## Embedding

The swerver integration (vsock spine, per-VM-per-worker, eventfd registration) is designed but not fully wired in production. nether runs standalone today.

## API stability

The library root (`src/root.zig`) and control protocol may change before 1.0. Downstream embedders should pin commits.

## Platform

nether is the **isolate + govern** layer. It does not replace a gateway (that's [swerver](https://docs.swerver.net)), billing rails (x402), or agent orchestration.

## Roadmap

Phases, done-lines, and the platform track are in [Roadmap](../roadmap.md). Architectural forks are recorded in [Decisions](../decisions.md).