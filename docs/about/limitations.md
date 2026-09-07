# Limitations

These are current source and integration limits, including unfinished work.
See [stack status](../stack.md) for the backend matrix and verification scope.

## Snapshot and backend differences

HVF and KVM both implement full snapshots, COW restore, and park. They use
different formats (NSNP v5 and NSKV v2), with build-sensitive device and CPU state.
Keep snapshots paired with the build and environment that created them.

HVF has additional clock handling, park-file consumption, storage transforms,
and resume demonstrations. Content-diff helpers are present, but control-driven
diff capture is not wired. KVM has no equivalent GPU or storage-transform
integration, and its new data/egress bridge wiring has not been live-verified in
this documentation audit. GPU device availability does not imply GPU state is
captured by a snapshot.

HVF persistent disk files are shared external state, not part of the COW RAM
image. Neither a snapshot nor the console restores arbitrary external services
or TCP peers. Midstream resume depends on the separate relay and specific
HVF restoration path demonstrated by the proof scripts.

## Guest and host scope

- Supported backends are macOS/aarch64 HVF and Linux/x86-64 KVM.
- ARM uses direct kernel boot; x86 Linux uses PVH. OVMF/UEFI and Windows support
  remain future work.
- Linux/aarch64, live migration, VFIO passthrough, and 3D GPU acceleration are
  not current supported paths.
- Hardware virtualization is required; there is no software CPU emulator.

## Integration and lifecycle

The current Swerver stack uses separate gateway, supervisor, and Nether processes.
The proposed single-process embedding and event-loop registration are unfinished.

The supervisor has an in-memory pool and no restart adoption. Reclaim uses
ensure/readiness timestamps, not active-request leases. The console relies on
gateway discovery and sampled VM state, with bounded in-memory histories.

## Stability and security

The library API and wire protocols are pre-1.0. Pin compatible source revisions,
rebake snapshots when updating, and read [versioning](../versioning.md).

There has been no external security audit. Guest-input validation and fuzz smoke
are defenses under development, not evidence that all malformed inputs are safe.
The [security policy](../security.md) explains the trust boundary and reporting.
