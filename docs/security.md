# Security posture

Nether's design assumes a hostile guest: arbitrary kernels and malformed device
input are part of the threat model. The goal is to prevent guest input from
corrupting host memory, escaping the VM, or hanging the VMM.

The full scope and private reporting instructions are in
[SECURITY.md](https://github.com/justinGrosvenor/nether/blob/main/SECURITY.md).

## Implemented defenses and their limits

- Guest-memory helpers provide bounds checks for device buffer access. Callers
  must also validate arithmetic, queue geometry, and state transitions.
- Virtio, vsock, terminal, and snapshot parsing have unit and fuzz-smoke coverage.
  The restore mutation scripts provide additional targeted checks.
- Snapshot readers check versions and layout fields; control commands use a
  versioned protocol.
- Hardening changes are recorded in the
  [changelog](https://github.com/justinGrosvenor/nether/blob/main/CHANGELOG.md).

These mechanisms do not establish that every guest access uses one checked path,
that all malformed snapshots are rejected safely, or that all invalid queue
states are handled. Finite fuzz-smoke runs are not continuous exhaustive fuzzing.
See [verification scope](stack.md#verification-scope) for recorded checks.

## Control-plane boundary

Nether's control and data sockets check the peer uid. Same-uid clients are inside
the process owner's trust boundary and can drive privileged guest operations.
The primary control client can mutate guest state; additional observers have
restricted commands.

This boundary is specific to Nether. Supervisor sockets, gateway admin APIs, and
console tokens have their own access rules; deployment must account for each.

## Maturity

Nether is pre-1.0 and has had no external security audit. The repository security
policy gives HVF the primary hardening scope and treats KVM as a reference
backend. New backend features do not imply equal security coverage.

Report suspected vulnerabilities privately through the repository Security tab
or the contact in the policy. Tests, proof scripts, and reviews support
development; they do not establish readiness for hostile production tenants.
