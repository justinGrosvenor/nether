# Changelog

All notable changes to nether are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

nether is **pre-1.0 (0.x)**: while the API and on-disk formats are still moving, a `0.x`
MINOR bump may include a breaking change (a patch never does). See
[docs/versioning.md](docs/versioning.md) for the stability policy and the three independent
version surfaces (release, snapshot format, control protocol).

## [Unreleased]

## [0.1.0] - 2026-07-14

The first public cut, grouped by capability rather than by commit.

### Added
- **Snapshot -> COW fork -> park/resume on Apple Hypervisor.framework.** Capture a running
  guest to one file and restore it by copy-on-write `mmap` (a fork shares the base's pages,
  copies only what it writes). Base vs park snapshot lifecycle; forks can re-park.
- **Storage stack for snapshots:** sparse RAM writes (zero-page holes), content-diff parks
  (store only pages diverged from a base, no HVF dirty-page log needed), `clonefile` base
  dedup (a derived base shares the base's blocks copy-on-write), an orphan-park TTL reaper,
  and opt-in deflate compression for durable bases (rehydrate-on-fork keeps the fast path).
  Driven by a declarative bake recipe.
- **Guest continuity across a park:** monotonic virtual-timer continuity, a PL031 RTC that
  catches the wall clock up on resume, and a CRNG reseed on fork (via vmgenid) so siblings
  do not share randomness.
- **Egress plane + park-while-awaiting-upstream:** hold a real upstream socket on the host
  and revive a parked `recv()` on a fork; per-VM data-plane bandwidth cap (govern pacing).
- **Control plane:** `__info__` / `__stats__` / `__help__`, command relay with an exit-code
  trailer, `__put__` / `__get__` file transfer, `__snapshot__` / `__park__`, and restore.
  Control protocol **v2** frames every reply uniformly (removing the v1 ambiguity); the
  version is reported in the handshake and clients adapt.
- **SDKs over the control protocol:** `nether` (Python) and `@nether/sdk` (TypeScript).
- **Reproducibility + CI:** a version-and-SHA256-pinned guest image, CI building both
  backends and running the suite under Debug / ReleaseSafe / ReleaseFast, and proof scripts
  that reproduce the fork/park/boot latency claims.

### Security
- Guest -> host is the primary threat model. Every guest-physical memory access goes through
  one bounds-checked, fail-closed accessor (an out-of-range address reads as zero and drops
  the write); guest-driven state (virtqueues, snapshot headers) is validated before it is
  trusted.
- Continuous fuzzing of the guest-facing parsers (virtio transport + devices, the vsock
  protocol engine, the terminal parser, the snapshot-header decoder), plus a black-box
  restore-parser mutation fuzzer, run in the test suite.
- Fixed a **guest-triggerable use-after-free** in the file-transfer capture path and a
  use-after-free in the data-plane bridge on shutdown; closed several DoS / resource-
  exhaustion edges; closed the control-protocol audit findings (exit clamp, jail TOCTOU,
  strict args, write interlock).
- Fixed a const-cast-write UB in the PL011 MMIO read path that returned 0 under release
  optimization (a broken guest serial console in release builds).

### Notes
- No external security audit yet; do not run untrusted guests in production. See
  [SECURITY.md](SECURITY.md) for the full threat model and how to report a vulnerability.
- The x86/KVM backend is the reference backend and trails the HVF path (not yet hardened to
  the same standard).
