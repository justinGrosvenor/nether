# Installation

nether type-checks on any host; it only **runs** on hardware virtualization: Linux with `/dev/kvm` (x86-64) or Apple Silicon with Hypervisor.framework (aarch64).

## Requirements

| Requirement | KVM path | HVF path |
| --- | --- | --- |
| **Zig 0.16.0** (stable) | yes | yes |
| **Host OS** | Linux x86-64 | macOS on Apple Silicon |
| **Hardware virt** | `/dev/kvm` + `vmx` or `svm` in CPU flags | M-series SoC |
| **Entitlements** | none | `com.apple.security.hypervisor` (ad-hoc codesign) |

## Build from source

```sh
git clone https://github.com/justinGrosvenor/nether.git
cd nether
zig build
zig build test
```

The default target is **x86_64-linux** (cross-compile from macOS is the normal dev workflow). Override with `-Dtarget=native` on Apple Silicon to build the HVF backend.

### macOS linking note

If `xcode-select` points into Xcode.app (common when doing iOS work), native linking may fail to find the SDK. Prefix host binaries that link libSystem:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools zig build test
```

Cross-compilation to Linux is unaffected.

### HVF: sign after every rebuild

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools zig build -Dtarget=native
codesign --sign - --entitlements nether.entitlements --force zig-out/bin/nether
```

Ad-hoc signing works for local development. Re-sign after each rebuild.

## Verify the toolchain

```sh
zig version    # 0.16.0
```

## Run the smoke test

```sh
zig build run
```

- **Linux + KVM**: runs under real hardware virtualization.
- **macOS + HVF**: runs the aarch64 first-light guest (PL011 + PSCI).
- **Other hosts**: cross-compiles only; `zig build run` will not execute a guest.

## Depend on nether as a library

nether exports an embeddable core from `src/root.zig`. The default binary in `src/main.zig` is a thin wrapper. [swerver](https://docs.swerver.net) is the intended host: allocator-injected, vsock and eventfds registered into swerver's `IoRuntime`.

!!! note "Embedding API"
    The library surface is still stabilizing. See [Platform thesis](../thesis.md) for the integration contract and [Decisions](../decisions.md) D2 for the device split.

## Next

- [Running on KVM](../running-on-kvm.md) for a full Linux guest on bare metal.
- [Running on HVF](../running-on-hvf.md) for the Apple Silicon development path.