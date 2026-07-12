# Security posture

nether runs a guest OS you may not trust, in the layer below it. The design assumes a
**hostile guest**: malformed or malicious guest input is the primary attack surface, and the
guest -> host boundary is where correctness matters most. This page describes how that line
is held. The full threat model (in scope / out of scope) and how to report a vulnerability
are in [SECURITY.md](https://github.com/justinGrosvenor/nether/blob/main/SECURITY.md).

## The line: guest to host

A guest may be fully hostile. It runs arbitrary kernels and feeds arbitrary bytes to every
device. The security goal is that **malformed or malicious guest input must never compromise
the host**: no memory corruption, no out-of-bounds access, no escape, no host-side hang from
a wedged guest. Breaking *the guest* from inside is the point of a sandbox, not a bug;
breaking *out of* the guest is the thing we defend against.

## How the line is held

- **One bounds-checked seam.** Every guest-physical memory access goes through a single
  overflow-safe accessor that fails closed: an out-of-range address reads as zero and drops
  the write, so a malicious descriptor ring can never steer the VMM outside guest RAM.
  Guest-driven device state (virtqueues, snapshot headers) is validated before it is trusted.
- **Continuous fuzzing.** The guest-facing parsers (virtio transport and devices, the vsock
  protocol engine, the terminal parser, the snapshot-header decoder) run always-on fuzz smoke
  in the test suite, alongside a black-box restore-parser mutation fuzzer. Fuzzing runs on
  every change, not as a one-off.
- **Adversarial review.** The guest -> host surface is reviewed adversarially. The most
  recent pass fixed a guest-triggerable use-after-free in the file-transfer path and closed
  several resource-exhaustion edges (see the [changelog](https://github.com/justinGrosvenor/nether/blob/main/CHANGELOG.md)).
- **Fail-closed formats.** A corrupt, truncated, or version-mismatched snapshot is rejected,
  not misread; the control protocol is versioned and self-describing. See
  [Versioning and stability](versioning.md).

## The control-plane trust boundary

The control and data sockets are gated to the **owning uid** (the same trust as the process
itself): a user who already runs as you can do anything the process can, so that is out of
scope by design. We still harden against a *buggy or hostile same-uid client* driving the
control socket into host memory-unsafety or a hang, as defense in depth.

## Honest limitations

- nether is **pre-1.0 and has had no external security audit**. "Malformed guest input must
  never corrupt the host" is a first-class, tested invariant, but do not run untrusted guests
  in production yet.
- The **x86/KVM backend** is the reference backend and is not yet hardened to the HVF
  standard; findings there are welcome but tracked as such.

## Reporting

Please report privately (not in a public issue) via the repository's **Security** tab
(*Report a vulnerability*) or by email. Details and the full threat model are in
[SECURITY.md](https://github.com/justinGrosvenor/nether/blob/main/SECURITY.md).
