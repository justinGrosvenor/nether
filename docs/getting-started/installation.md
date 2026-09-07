# Installation

Builds require **Zig 0.16.0**. VM execution requires hardware virtualization:

| Backend | Host requirement |
| --- | --- |
| HVF | Apple Silicon macOS, signed hypervisor entitlement |
| KVM | Linux x86-64, access to `/dev/kvm` |

## Build from source

```sh
git clone https://github.com/justinGrosvenor/nether.git
cd nether
zig build test
zig build -Dtarget=x86_64-linux
```

The default target is x86-64 Linux. Host tests run on the build host without
booting a VM. A successful cross-build is not a backend runtime check.

On Apple Silicon:

```sh
zig build -Dtarget=native
./zig-out/bin/nether
```

The native macOS default build signs the **installed** binary with the
hypervisor entitlement. Use that installed path to run it. `zig build run`
uses a cached build artifact, which is not the path signed by the install step.

`-Dcodesign=false` disables automatic signing. For an explicit signing or
verification command, see [code signing](../codesigning.md). Explicit
`zig build install` also bypasses the default signing step.

If native linking cannot find the SDK when Xcode.app is selected:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools zig build -Dtarget=native
DEVELOPER_DIR=/Library/Developer/CommandLineTools zig build test
```

On a KVM host, run the Linux artifact with `./zig-out/bin/nether`.
Without guest artifacts, each backend runs its built-in serial smoke guest.

## Full guests and integration

- [HVF runbook](../running-on-hvf.md): ARM Image/initramfs preparation.
- [KVM runbook](../running-on-kvm.md): PVH kernel and initramfs.
- [Provisioning](../provisioning.md): warm HVF base recipes.
- [Stack status](../stack.md): gateway, supervisor, VM, and console boundaries.

The current Swerver integration launches Nether as separate VM processes.
The library exports in `src/root.zig` are available for embedding work, but
the proposed single-process gateway integration is not the current topology.
