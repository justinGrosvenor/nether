# Security policy

nether is a type-2 hypervisor: it runs a guest OS you may not trust, in the layer
below it. Its security story is about a **trust boundary**, so please read the threat
model before reporting — it determines what counts as a vulnerability.

## Reporting a vulnerability

Please report privately, **not** in a public issue:

- Preferred: GitHub's **private vulnerability reporting** (this repo's *Security* tab
  -> *Report a vulnerability*).
- Or email **justingrosvenor@gmail.com** with `nether security` in the subject.

Include what you need to reproduce: the input (snapshot file, guest image, control
command, or a description of the malformed data), the config, and the observed effect
(crash, hang, out-of-bounds, escape). A proof-of-concept is welcome but not required.

This is a personal open-source project, not a funded program: there is no bug bounty,
but credited disclosure is appreciated and I will acknowledge reports and work in good
faith on a fix and coordinated disclosure.

## Threat model

The **primary attacker surface is the guest**. A guest may be fully hostile — it can
run arbitrary kernels and feed arbitrary bytes to every device. The security goal is
that **malformed or malicious guest input must never compromise the host**: no memory
corruption, no out-of-bounds access, no escape, no host-side hang from a wedged guest.

In scope (please report):

- Host memory-unsafety, escape, or crash driven by **malformed guest input** — virtio
  device queues (blk, net, rng, vsock), the vsock protocol engine, or any guest-driven
  MMIO/register path.
- Host memory-unsafety or crash from a **corrupt, truncated, or hostile snapshot file**
  fed to restore/validate (`restore_from` / `validate_snapshot`).
- A **misbehaving same-uid control client** driving the control socket into host
  memory-unsafety or a hang (defense-in-depth — see the trust note below).
- A host-side hang or unbounded resource use that a hostile guest can trigger.

Out of scope (by design):

- **A malicious same-uid local user.** The control and data sockets are gated to the
  owning uid (same trust as the process itself): a user who already runs as you can do
  anything the process can. We still harden against a *buggy or hostile* same-uid client
  (above), but "a same-uid user can affect the sandbox" is not a vulnerability.
- **Guest-internal compromise.** Code running in the guest breaking the guest is the
  point of a sandbox, not a bug. Escape *out of* the guest is in scope.
- **The x86/KVM backend.** It is the reference backend and trails the HVF path; it is
  not yet hardened to the standard above. Findings are welcome but tracked as such.
- Denial of service *by* the guest against *itself*, or resource exhaustion the operator
  controls via configured limits.

## Supported versions

nether is pre-1.0 and moves fast; only `main` is supported. Please reproduce against
the current `main` before reporting.
