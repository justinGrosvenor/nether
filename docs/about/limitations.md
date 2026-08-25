# Limitations

Honest scope notes for the current tree. These are intentional cuts and sequencing choices, not a backlog of unknown bugs.

## Backends are asymmetric

| Track | Maturity |
| --- | --- |
| **HVF / aarch64** | Platform layer live: Linux boot, virtio (blk/net/vsock/gpu), snapshot-fork, control plane, govern, observe, meter, SMP |
| **KVM / x86-64** | PVH Linux boot, virtio-blk/net/vsock, SMP, IOAPIC; the platform layer (control plane, metering, govern, observe, watchdogs, slirp + egress firewall) and the cross-process snapshot fork (COW restore, SMP fork, `__snapshot__`/`__park__`, vmgenid reseed), all **run-verified on bare metal**. Remaining gap: virtio-gpu |

KVM parity is tracked in the [roadmap](../roadmap.md).

## Snapshot / restore

Snapshot save, COW restore (`restore=1` / `restore_from=`), and the on-demand `__snapshot__`/`__park__` capture work on **both** backends. The image formats differ (HVF vs KVM `NSKV`) and are same-host, same-build: a base is not portable across backends or machines. Still HVF-only: the rewind demo, GPU scanout capture, deflate-compressed durable bases, and incremental (diff) snapshots. See [Running on KVM](../running-on-kvm.md#5-snapshot-and-fork) for the x86 flow.

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