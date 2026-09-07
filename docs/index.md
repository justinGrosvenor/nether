# nether

<div class="nether-tagline">the layer below</div>

Nether is a type-2 VMM in Zig. It boots Linux guests on Apple Silicon using
Hypervisor.framework and on Linux/x86-64 using KVM, then restores warm snapshots
into separate VMs with copy-on-write RAM.

The inspected Swerver stack runs a gateway, a separate VM supervisor, per-VM
Nether processes, and a console bridge. Read
[current stack and backend status](stack.md) for ownership, capabilities, and
verification limits. The exported library also supports work toward embedding.

## Start here

- [Installation](getting-started/installation.md): Zig 0.16.0, build targets, signing.
- [Running on HVF](running-on-hvf.md): Apple Silicon guests and configuration.
- [Running on KVM](running-on-kvm.md): x86-64 PVH guests and snapshots.
- [Forking](forking.md): capture, restore, and the HVF resume demonstrations.
- [Provisioning](provisioning.md): bake an HVF base with a TOML recipe.
- [Control protocol](control-protocol.md): control commands and framing.
- [Security posture](security.md): threat model and limits.
- [Source architecture](architecture.md): code map.
- [Roadmap](roadmap.md): remaining work and historical milestone notes.

## Build check

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

Nether is pre-1.0. Tests and build checks are distinct from live VM verification;
see the [recorded check scope](stack.md#verification-scope).
