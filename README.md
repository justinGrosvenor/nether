# nether

**Linux microVMs that fork like processes.** nether is a type-2 hypervisor (VMM)
written in Zig. Boot a Linux guest once, snapshot it warm, then fork that snapshot
into fresh VMs in **~70 ms** each — resuming exactly where the image froze, even
mid-request. It runs in the layer below the guest, hence the name.

**Documentation:** [docs.nether.dev](https://docs.nether.dev) (source in [`docs/`](docs/index.md)).

## The idea

A normal VM boots from cold every time. nether treats a running Linux VM as
something you can snapshot, kill, and bring back — like `fork()` for a whole guest:

- **Cold boot once (~0.5 s)** to a ready, serving base image.
- **Warm-fork it in ~70 ms**, copy-on-write: each fork shares the base's pages and
  only copies what it writes, so a fork is cheap in both time and memory.
- **Resume mid-flight.** Because the whole guest is captured, a fork wakes up
  inside the exact system call the snapshot froze on. You can accept a request on
  one VM, snapshot and kill it, and **complete the reply from a different VM** that
  didn't exist when the request arrived — the upstream connection is held by the
  host across the gap.

The monotonic clock stays continuous across a park; the wall clock catches up to
real time on resume; forks reseed their CRNG so siblings don't share randomness.

> Numbers are measured on Apple Silicon (HVF), a 512 MB / 2-vCPU guest. "~70 ms" is
> a **warm fork / snapshot restore**, not a cold boot — bigger guests copy more
> pages on resume, so treat it as an order of magnitude, not a guarantee.

## What it is

- A **type-2 VMM in Zig**, modern guests only (no legacy hardware emulation).
- **Primary backend: Apple Hypervisor.framework on macOS / aarch64.** This is the
  developed path — it boots Linux, runs SMP, virtio-blk/net/rng/vsock, a control
  plane, snapshot + COW fork + park/resume, an egress plane, and a read-only web
  console.
- **Reference backend: KVM on Linux / x86-64.** The original backend; PVH-boots
  Linux 6.12 to an interactive shell over virtio-pci. It trails the HVF path.
- The hypervisor is a **compile-time backend seam**, so the guest-facing device and
  protocol code is shared across both.
- **Optional, off by default:** per-VM usage metering with an x402 settlement
  record on teardown. General (unmetered) workloads are the default path.

The threat model treats **malformed guest input as the primary attacker surface**;
the guest-facing parsers are continuously fuzzed.

## Build & run (Apple Silicon)

Requires **Zig 0.16.0** ([ziglang.org/download](https://ziglang.org/download/)) and
an Apple Silicon Mac. The HVF backend needs a hypervisor entitlement, or boots fail
`HV_DENIED`:

```sh
zig build -Dtarget=native
codesign --sign - --entitlements nether.entitlements --force zig-out/bin/nether
./zig-out/bin/nether
```

A guest kernel `Image` + rootfs is **not** checked in (it's gitignored). See
[`docs/running-on-hvf.md`](docs/running-on-hvf.md) for how to fetch/build one and
for a sample `nether.conf`. If `xcode-select` points into Xcode.app (e.g. during
iOS work), prefix host-linking commands with
`DEVELOPER_DIR=/Library/Developer/CommandLineTools`.

For the x86/KVM reference backend, see
[`docs/running-on-kvm.md`](docs/running-on-kvm.md).

```sh
zig build test          # run the test suite (includes the always-on fuzz smoke)
```

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

## License

[Apache-2.0](LICENSE).
