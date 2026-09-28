# nether

<div class="nether-tagline">the layer below</div>

Nether is a type-2 VMM in Zig. It boots Linux guests on Apple Silicon using
Hypervisor.framework and on Linux/x86-64 using KVM, then restores warm snapshots
into separate VMs with copy-on-write RAM.

Start from a running application, fork isolated instances from its snapshot,
and drive each VM through a control socket. Nether provides guest networking,
data/egress bridges, resource limits, usage metering, and a terminal view.

In the Swerver stack, the gateway routes requests, nether-supervisor manages
the VM pool, and swerver-console provides the UI. See the [stack overview](stack.md)
for the architecture and backend matrix.

## Start here

- [Installation](getting-started/installation.md): Zig 0.16.0, build targets, signing.
- [Running on HVF](running-on-hvf.md): Apple Silicon guests and configuration.
- [Running on KVM](running-on-kvm.md): x86-64 PVH guests and snapshots.
- [Forking](forking.md): capture, restore, and the HVF resume demonstrations.
- [Provisioning](provisioning.md): bake an HVF base with a TOML recipe.
- [Control protocol](control-protocol.md): control commands and framing.
- [Security posture](security.md): guest trust boundary and reporting.
- [Source architecture](architecture.md): code map.
- [Roadmap](roadmap.md): remaining work and historical milestone notes.

## Build and run

```sh
zig build test
zig build -Dtarget=x86_64-linux
```

To run locally on Apple Silicon:

```sh
zig build -Dtarget=native
./zig-out/bin/nether
```

The native install step signs the installed binary by default. With no kernel
present, it runs the built-in serial smoke guest. Full Linux guests require the
artifacts described in the backend runbooks.

Explore the [live VM examples](reproducing.md), or read the
[recorded test results](stack.md#verification-scope).
