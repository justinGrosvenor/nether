# Reproducing the claims

Every latency and behavior claim in the README and design docs has a live proof
script under [`scripts/`](../scripts/). This page is the index: what each proves and
how to run it.

> **These are live HVF proofs.** They boot real guests on Apple Hypervisor.framework,
> so they need an **Apple Silicon Mac**. They cannot run on the x86/KVM reference
> backend or in CI. The numbers below are measured on the author's machine (a
> 512 MB / 2-vCPU guest); treat them as an order of magnitude, not a guarantee. Bigger
> guests copy more pages on resume.

## Prerequisites

1. **Zig 0.16.0** ([ziglang.org/download](https://ziglang.org/download/)), the
   0.16.0 *stable* release. Recent dev nightlies do **not** link against current Xcode
   SDKs; pin stable.
2. A **guest image** in `kernels/` (gitignored). Build one:
   ```sh
   ./scripts/fetch-guest-image.sh
   ```
3. A **built, codesigned** binary (the HVF backend needs the hypervisor entitlement):
   ```sh
   zig build -Dtarget=native
   codesign --sign - --entitlements nether.entitlements --force zig-out/bin/nether
   ```
4. **Python 3** (the proof harnesses are stdlib-only) and `NETHER_ROOT` set if the
   repo is not at `~/nether`:
   ```sh
   export NETHER_ROOT="$(pwd)"
   ```

Then run any script directly, e.g. `python3 scripts/fork_serve.py`.

## The proofs

### Fork, snapshot, and warm serving

| Script | Proves |
| --- | --- |
| `fork_serve.py` | A base VM whose in-guest HTTP server is already running is snapshotted and warm-forked; the fork serves requests **instantly** through its own socket, inheriting the exact warm server process (same PID via CoW), with an independent request counter, while the parent keeps serving. |
| `pool_serve.py` | A pool of warm VMs forked from one base, each serving independently. |
| `park_density_proof.py` | A parked *fleet*, measured: bake one base, fork N VMs, park them, and show the per-VM memory/latency cost of density. |
| `snapshot_quiesce_proof.py` | The snapshot is taken at a clean quiesce point: no in-flight device state is lost across capture. |

### Park and resume (mid-flight)

| Script | Proves |
| --- | --- |
| `park_await_proof.py` | A guest blocked in `recv()` on an outbound request is snapshotted and **killed**; when the upstream reply arrives, a restored fork completes the *same* `recv()` with the reply bytes. Nobody's VM runs while the upstream is slow (~66 ms restore). |
| `park_multi_proof.py` | One VM with **four concurrent** in-flight upstream requests is parked and revived, and all four resume. |
| `park_timer_proof.py` | A woken fork's virtual timer resumes at its captured value: the snapshot is the guest's last live moment, monotonic time is continuous across the gap. |
| `wallclock_proof.py` | Fresh boot has a real wall clock (year ≥ 2026, not 1970, from the PL031 RTC); across a park the wall clock freezes while monotonic stays continuous, and one `hwclock -s` reconciles it. |

### Fork determinism / entropy

| Script | Proves |
| --- | --- |
| `fork_entropy_proof.py` | Sibling forks diverge in randomness (they do **not** share a CRNG state after fork). |
| `vmgenid_proof.py` | The kernel-native reseed via vmgenid: with the gate off two siblings emit identical randomness; with it on they diverge. |

### Data plane / egress

| Script | Proves |
| --- | --- |
| `data_plane_pacing.py` | The per-conn output cap paces upstream throughput to the configured rate (and ≪ uncapped). |
| `data_plane_fairness.py` | A large transfer on one data-plane conn does **not** starve concurrent conns (no host-side head-of-line blocking): conn A streams ~1.2 GB while conn B keeps serving small requests. |
| `relay_proof.py` | The two relay/pipe audit fixes, each verified on its own fresh VM. |

### Control protocol

| Script | Proves |
| --- | --- |
| `proto_v2.py` | Control-protocol v2 (frame-everything) end to end. |

## Fuzzing and tests (no guest image needed)

The parser and protocol test suite, including the always-on fuzz smoke over the
guest-facing surfaces, runs on any host, cross-compiled, no HVF required:

```sh
zig build test          # 249 tests + fuzz smoke; must be green
```

`scripts/fuzz_restore.py` drives the snapshot-restore parser with malformed inputs
(the guest→host boundary the review hardened).
