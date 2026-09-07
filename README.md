# nether

[![CI](https://github.com/justinGrosvenor/nether/actions/workflows/ci.yml/badge.svg)](https://github.com/justinGrosvenor/nether/actions/workflows/ci.yml)

**Linux microVMs that fork from a warm snapshot.** Nether is a type-2 VMM written
in Zig. It boots Linux, captures guest state, and restores separate VM processes
with copy-on-write RAM.

**Documentation:** [project site](https://justingrosvenor.github.io/nether/),
[source](docs/index.md), and [current stack and backend status](docs/stack.md).

## Current implementation

- **macOS / Apple Silicon (HVF):** Linux boot, SMP, virtio-blk/net/rng/vsock,
  2D GPU, control sockets, snapshots, COW fork, park/resume, and egress bridging.
  The snapshot storage tools and mid-request resume demonstrations target this backend.
- **Linux / x86-64 (KVM):** PVH Linux boot, SMP, virtio-blk/net/rng/vsock,
  slirp networking with an egress firewall, control sockets, metering, snapshots,
  COW restore, and park. Backend coverage differs; see the
  [capability table](docs/stack.md#backend-capabilities).
- **Optional metering:** per-VM usage counters and teardown settlement output.
  The surrounding platform owns payment processing and durable accounting.

The inspected Swerver integration runs a gateway, a separate
`nether-supervisor` daemon, and one `nether` process per VM. The
`swerver-console` bridge observes and controls those services. Nether also
exports a library through `src/root.zig`; embedding it into one gateway process
remains an integration design, rather than the topology used by this stack.

## Fork and resume

A base captures an already running guest. Forks map the base RAM privately and
copy pages as they write. Each fork still needs a new VMM process and VM/device
setup; it is not a host process `fork()`.

Historical Apple Silicon measurements recorded approximately 10 ms to a driveable
restored VM and 25 ms to a first response from an already warm application, using
a 512 MiB / 2-vCPU guest. These are different measurements from a complete
gateway/supervisor request. They are not current benchmark guarantees.

The HVF proof scripts also exercise mid-request resume, clock handling, and CRNG
reseeding. Continuing an external connection requires the host relay used by
those proofs; a memory snapshot alone cannot preserve a host TCP connection.
See [forking](docs/forking.md) and [reproducing](docs/reproducing.md).

## Build and run

Requires **Zig 0.16.0**. On Apple Silicon:

```sh
zig build -Dtarget=native
./scripts/fetch-guest-image.sh
./zig-out/bin/nether
```

The native macOS install step signs `zig-out/bin/nether` with the hypervisor
entitlement by default. `-Dcodesign=false` disables signing; see
[code signing](docs/codesigning.md). Run the installed binary shown above.

The kernel and rootfs are not checked in. The image script builds the HVF guest
artifacts under `kernels/`. If native linking cannot find the SDK, prefix the
build with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`.

```sh
zig build test                         # host tests; no VM boot required
zig build -Dtarget=x86_64-linux         # KVM binary; this is also the default target
```

Running KVM requires an x86-64 Linux host with access to `/dev/kvm` and the
guest layout in [Running on KVM](docs/running-on-kvm.md). For HVF configuration,
see [Running on HVF](docs/running-on-hvf.md).

[Provisioning](docs/provisioning.md) describes the HVF base recipe runner.
[Swerver guest per request](docs/swerver-guest.md) describes the application demo.

## Security and verification

The design assumes a hostile guest. Bounds-checked guest-memory helpers, device
validation, unit tests, and fuzz-smoke tests provide defenses, but do not establish
that every guest-input path is safe. Nether is pre-1.0 and has had no external
security audit. See [SECURITY.md](SECURITY.md) for scope and private reporting.

The [stack status](docs/stack.md#verification-scope) separates compile and unit
checks from live VM proofs. Passing host tests does not verify an end-to-end
deployment or establish production readiness.

## Layout

```text
src/main.zig       executable: backend boot, restore, and runtime wiring
src/root.zig       library exports
src/hv/           HVF and KVM backends, VM state, KVM snapshots
src/agent/        control, metering, HVF snapshots, shared platform setup
src/virtio/       transport and devices, including the vsock protocol engine
src/chipset/      platform devices, interrupt and bus plumbing
src/boot/         PVH/ELF loading and device tree generation
src/mem/          guest memory maps
src/net/          user-mode networking
src/common/       config, host helpers, locks
src/vt/           terminal parser and screen
src/fuzz.zig      guest-facing parser fuzz smoke
docs/             architecture, protocols, operational guides, history
```

`build.zig.zon` declares version 0.1.1, Zig 0.16.0, and no external package
dependencies. See [versioning](docs/versioning.md).

## Development and license

The project is developed with AI assistance. Source review, automated checks,
and live runtime proofs have distinct scopes; none substitutes for the others.

[Apache-2.0](LICENSE).
