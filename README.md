# nether

[![CI](https://github.com/justinGrosvenor/nether/actions/workflows/ci.yml/badge.svg)](https://github.com/justinGrosvenor/nether/actions/workflows/ci.yml)

**Linux microVMs that fork like processes.** nether is a type-2 hypervisor (VMM)
written in Zig. Boot a Linux guest once, snapshot it warm, then fork that snapshot
into fresh VMs in **~10 ms** each, resuming exactly where the image froze, even
mid-request. It runs in the layer below the guest, hence the name.

**Documentation:** [docs.nether.dev](https://docs.nether.dev) (source in [`docs/`](docs/index.md)). For the non-technical version of why this matters, see [nether in one page](docs/nether-for-execs.md).

## The idea

A normal VM boots from cold every time. nether treats a running Linux VM as
something you can snapshot, kill, and bring back, like `fork()` for a whole guest:

- **Cold boot once (~0.5 s)** to a ready, serving base image.
- **Warm-fork it in ~10 ms** to a live, driveable VM (a first served request through a
  warm in-guest server lands in ~25 ms), copy-on-write: each fork shares the base's
  pages and only copies what it writes, so a fork is cheap in both time and memory.
- **Resume mid-flight.** Because the whole guest is captured, a fork wakes up
  inside the exact system call the snapshot froze on. You can accept a request on
  one VM, snapshot and kill it, and **complete the reply from a different VM** that
  didn't exist when the request arrived. The upstream connection is held by the
  host across the gap.

The monotonic clock stays continuous across a park; the wall clock catches up to
real time on resume; forks reseed their CRNG so siblings don't share randomness.

> Numbers are measured on Apple Silicon (HVF), a 512 MB / 2-vCPU guest, and are
> reproducible via the proof scripts under [`scripts/`](scripts/). "~10 ms" is a
> **warm fork / snapshot restore** to a driveable VM (not a cold boot); ~25 ms is fork
> to a first served request through a warm app. Bigger guests copy more pages on
> resume, so treat these as order-of-magnitude, not guarantees.

## What it is

- A **type-2 VMM in Zig**, modern guests only (no legacy hardware emulation).
- **Primary backend: Apple Hypervisor.framework on macOS / aarch64.** This is the
  developed path: it boots Linux, runs SMP, virtio-blk/net/rng/vsock, a control
  plane, snapshot + COW fork + park/resume, an egress plane, and a read-only web
  console.
- **Reference backend: KVM on Linux / x86-64.** The original backend; PVH-boots
  Linux 6.12 to an interactive shell over virtio-pci. It trails the HVF path.
- The hypervisor is a **compile-time backend seam**, so the guest-facing device and
  protocol code is shared across both.
- **Optional, off by default:** per-VM usage metering with an x402 settlement
  record on teardown. General (unmetered) workloads are the default path.

## Security

The design assumes a **hostile guest**: malformed or malicious guest input is the
primary attack surface, and the guest→host boundary is where correctness matters
most. Two disciplines hold that line:

- **One bounds-checked seam.** Every guest-physical memory access goes through a
  single overflow-safe accessor that fails closed: an out-of-range address reads
  as zero and drops the write, so a malicious descriptor ring can never steer the
  VMM outside guest RAM. Guest-driven device state (virtqueues, snapshot headers)
  is validated before it is trusted.
- **Continuous fuzzing + adversarial review.** The guest-facing parsers (virtio
  transport and devices, the vsock protocol engine, the terminal parser, the
  snapshot-header decoder) run always-on fuzz smoke in the test suite, and the
  guest→host surface is reviewed adversarially. The most recent pass fixed a
  guest-triggerable use-after-free in the file-transfer path and closed several
  resource-exhaustion edges (see the commit history).

nether is pre-1.0 and has had **no external audit**. Don't run untrusted guests in
production yet. But "malformed guest input must never corrupt the host" is a
first-class, tested invariant here, not an afterthought.

## Build & run (Apple Silicon)

Requires **Zig 0.16.0** ([ziglang.org/download](https://ziglang.org/download/)) and
an Apple Silicon Mac. The HVF backend needs a hypervisor entitlement, or boots fail
`HV_DENIED`:

```sh
zig build -Dtarget=native
codesign --sign - --entitlements nether.entitlements --force zig-out/bin/nether
./scripts/fetch-guest-image.sh    # fetch/build a bootable aarch64 Linux guest
./zig-out/bin/nether              # boots kernels/Image to an interactive shell
```

The guest kernel `Image` + rootfs is **not** checked in (it's gitignored);
`scripts/fetch-guest-image.sh` builds one from a pinned Alpine release into
`kernels/`. See [`docs/running-on-hvf.md`](docs/running-on-hvf.md) for the manual
steps and a sample `nether.conf`. If `xcode-select` points into Xcode.app (e.g.
during iOS work), prefix host-linking commands with
`DEVELOPER_DIR=/Library/Developer/CommandLineTools`.

For the x86/KVM reference backend, see
[`docs/running-on-kvm.md`](docs/running-on-kvm.md).

```sh
zig build test          # run the test suite (includes the always-on fuzz smoke)
```

Every latency and behavior claim above has a live proof script under `scripts/`;
[`docs/reproducing.md`](docs/reproducing.md) indexes what each proves and how to run it.

**Provisioning a base to fork:** [`docs/provisioning.md`](docs/provisioning.md) walks the path
from a guest image to a warm base to a fork, driven by a declarative recipe
([`examples/base.nether.toml`](examples/base.nether.toml), run with `scripts/bake.py`).

## Layout

```
src/main.zig       thin binary wrapper over the core
src/root.zig       library root a host platform embeds
src/hv/            hypervisor backends: HVF (Apple, aarch64) + KVM (Linux, x86-64) + shared seam
src/agent/         control plane, metering, snapshot / fork / park lifecycle
src/virtio/        virtio devices: blk, net, rng, vsock (protocol engine + device glue)
src/chipset/       platform devices: GIC, PL011 UART, PL031 RTC, timer, PSCI
src/boot/          guest boot: DTB, kernel/initramfs load, memory map
src/mem/           guest physical memory map (single source of truth)
src/net/           host networking (slirp-style egress)
src/common/        shared helpers (config, host utils, locks)
src/vt/            terminal subsystem: vendored parser + screen grid
src/fuzz.zig       always-on fuzz-smoke for the guest-facing parsers
docs/              design · roadmap · decisions · control protocol · runbooks
```

## Toolchain

Targets **Zig 0.16.0 stable**. `build.zig.zon` pins `minimum_zig_version` and has
no external dependencies, so the build is self-contained. See
[`docs/bringup-notes.md`](docs/bringup-notes.md).

## How it's built

nether is developed with heavy AI assistance (Claude Code), and the commit cadence
reflects that. That's stated plainly because the discipline is the point: velocity
only counts if the result is correct, so correctness here is *demonstrated*, not
asserted: a green test suite on every change, always-on fuzzing of the guest-facing
parsers, proof scripts that reproduce the fork/park/boot latency claims, and
adversarial review of the guest→host boundary. Authorship is owned openly; the
verification is what earns the trust.

## License

[Apache-2.0](LICENSE).
