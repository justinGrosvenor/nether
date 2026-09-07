# Nether in one page

Nether reduces repeated guest startup work by cloning an already warm Linux VM.
Boot the guest and application once, capture a base, then restore separate VMs
whose memory is backed by that base using copy-on-write.

Each restore still creates a VMM process and hardware VM and sets up its devices.
The benefit is avoiding repeated Linux boot and application initialization, not
eliminating the cost of each tenant environment.

## Where it fits

The inspected stack has four layers:

| Component | Responsibility |
| --- | --- |
| Swerver | Accept requests and route tenant traffic |
| nether-supervisor | Allocate, restore, and reclaim tenant VMs |
| Nether | Execute and control each guest |
| swerver-console | Observe the stack and drive demonstrations |

The gateway, supervisor, and VMs are separate processes. A single-process
embedding is a future integration option.

This can support experiments in per-tenant services and isolated code execution.
Hardware isolation is one boundary; host device parsing, guest images, resource
policy, and lifecycle correctness still determine whether the system is ready
for a particular workload.

## Evidence and limits

Historical HVF results recorded roughly 10 ms to a driveable restored VM and
25 ms to the first response from a warm application on a 512 MiB / 2-vCPU Apple
Silicon guest. Complete gateway/supervisor request timings include additional
work and have separate measurements. These figures are not throughput or
latency guarantees.

The HVF proof scripts also demonstrate parking a guest during an outbound call
and continuing the call in a restored VM. A separate host relay holds the
upstream connection while the VM is absent. That relay and snapshot storage
still consume resources.

Linux/x86 KVM now implements snapshot/COW restore too, but backend features and
full-stack verification differ. Nether is pre-1.0, has no external security
audit, and does not yet provide multi-host scheduling or durable orchestration
and accounting.

See [current stack status](stack.md), [the proof index](reproducing.md), and
[limitations](about/limitations.md) for the evidence behind these boundaries.
