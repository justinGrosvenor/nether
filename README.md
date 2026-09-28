# nether

[![CI](https://github.com/justinGrosvenor/nether/actions/workflows/ci.yml/badge.svg)](https://github.com/justinGrosvenor/nether/actions/workflows/ci.yml)

**Linux microVMs that fork from a warm snapshot.** Nether is a type-2 VMM written
in Zig, running on Apple Silicon through Hypervisor.framework and on Linux/x86-64
through KVM.

Boot Linux once, start your application, and capture its running state. Nether
restores that snapshot into separate VMs with copy-on-write RAM, so each instance
starts with the application already loaded. Control sockets, guest networking,
resource limits, and usage metering make those VMs usable from a host application
or a tenant-serving platform.

[Documentation](https://justingrosvenor.github.io/nether/) ·
[Architecture](docs/architecture.md) · [Forking](docs/forking.md) ·
[Roadmap](docs/roadmap.md)

## What you can do

- **Fork a running guest.** Capture CPU, RAM, and device state, then restore
  independent VM processes from a shared snapshot base.
- **Park and resume work.** Capture a guest and stop its VMM process. The HVF
  park/wake flow can resume an application blocked on an outbound request while
  a separate host relay holds the upstream connection.
- **Drive Linux over a control socket.** Run guest commands, transfer files,
  inspect state, take snapshots, and shut down through a versioned protocol.
- **Serve ordinary applications.** A vsock forwarder connects host Unix sockets
  to a guest's loopback TCP service. Virtio networking provides slirp egress
  with allow/block rules and bandwidth limits.
- **Govern and observe each VM.** Set runtime, CPU, idle, output, and connection
  limits; inspect usage counters, the event journal, and terminal state.

Both backends implement Linux boot, SMP, virtio-blk/net/rng/vsock, snapshots,
COW restore, and park. HVF also provides a 2D virtio GPU and snapshot storage
tooling. See the [backend matrix](docs/stack.md#backend-capabilities) for details.

## Build and run

Requires **Zig 0.16.0**. On an Apple Silicon Mac:

```sh
zig build -Dtarget=native
./scripts/fetch-guest-image.sh
./zig-out/bin/nether
```

The build signs the installed executable with the hypervisor entitlement. The
image script prepares a Linux kernel and rootfs under `kernels/`; launching Nether
then boots the guest. See [Running on HVF](docs/running-on-hvf.md) for configuration
and [code signing](docs/codesigning.md) for signing options and SDK setup.

For Linux/x86-64:

```sh
zig build -Dtarget=x86_64-linux
```

Run on a host with `/dev/kvm`, using the kernel and initramfs setup in
[Running on KVM](docs/running-on-kvm.md).

## From a guest to a service

Use [provisioning recipes](docs/provisioning.md) to prepare an HVF guest with its
application and capture a reusable base. The [forking guide](docs/forking.md)
walks through capture, restore, and park/wake; the
[control protocol](docs/control-protocol.md) describes the host API.

In the Swerver stack, a gateway routes tenant requests, `nether-supervisor`
launches and pools Nether VMs, and `swerver-console` provides the UI. Requests
flow through each VM's data socket to its guest service. Start with the
[Swerver guest example](docs/swerver-guest.md) or the [stack overview](docs/stack.md).
Nether also exposes its VM and device modules as a Zig library through
[`src/root.zig`](src/root.zig).

## Development

```sh
zig build test
```

The suite covers guest-facing parsers, devices, snapshots, and control plumbing,
including fuzz-smoke tests. The [proof scripts](docs/reproducing.md) exercise live
VM workflows; [recorded results](docs/stack.md#verification-scope) document the
checks and environments used.

| Path | Contents |
| --- | --- |
| `src/main.zig`, `src/root.zig` | Executable and library entry points |
| `src/hv/`, `src/boot/`, `src/chipset/` | Host backends, guest boot, platform devices |
| `src/virtio/`, `src/mem/`, `src/net/` | Virtio devices, guest memory, networking |
| `src/agent/`, `src/vt/` | Control plane, snapshots, metering, terminal |
| `tools/`, `scripts/` | Guest image builders, provisioning, runtime proofs |
| `docs/` | Guides, architecture, protocols, project history |

Nether is developed with AI assistance. See [CONTRIBUTING.md](CONTRIBUTING.md)
for development conventions and [SECURITY.md](SECURITY.md) for the guest trust
boundary and private vulnerability reporting.

[Apache-2.0](LICENSE).
