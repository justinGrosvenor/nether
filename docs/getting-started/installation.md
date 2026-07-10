# Installation

nether type-checks on any host; it only **runs** on hardware virtualization: Linux with `/dev/kvm` (x86-64) or Apple Silicon with Hypervisor.framework (aarch64).

## Requirements

| Requirement | KVM path | HVF path |
| --- | --- | --- |
| **Zig 0.16.0** (stable) | yes | yes |
| **Host OS** | Linux x86-64 | macOS on Apple Silicon |
| **Hardware virt** | `/dev/kvm` + `vmx` or `svm` in CPU flags | M-series SoC |
| **Entitlements** | none | `com.apple.security.hypervisor` (ad-hoc codesign) |

Get Zig 0.16.0 (stable) from [ziglang.org/download](https://ziglang.org/download).

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

`zig build test` always runs on the host (no KVM/HVF required).

To **execute** a guest, you need a runnable binary on hardware virt:

| Host | Command |
| --- | --- |
| **Linux + KVM** | `zig build run` (default x86_64-linux artifact) |
| **macOS + HVF** | `zig build -Dtarget=native` then codesign, then `./zig-out/bin/nether` |

On macOS, `zig build run` with the default target cross-compiles a Linux binary; it does **not** run HVF locally. Use `-Dtarget=native` and codesign for the Apple Silicon path.

Expected smoke output (no kernel in cwd):

- **KVM**: `Nether lives. Phase 0: real-mode guest over COM1.`
- **HVF**: `Nether lives. Phase 0: aarch64 guest over MMIO UART.`

Both end with `[nether] guest shutdown.`

## Shipping shape: embedded in swerver

The edge runtime ships as **one binary**: [swerver](https://docs.swerver.net) imports
embedded nether. The `nether` executable built from `src/main.zig` is a thin
dev/bringup wrapper around the library in `src/root.zig` — useful for KVM/HVF
smoke tests and platform work without rebuilding the gateway.

In production, swerver owns the process: allocator-injected nether core, vsock and
device eventfds registered into swerver's `IoRuntime`, per-VM-per-worker pinning.

!!! note "Embedding API"
    The library surface is still stabilizing. See the [control protocol](../control-protocol.md) for the integration contract and [Decisions](../decisions.md) D2 for the device split.

## Next

- [Running on KVM](../running-on-kvm.md) for a full Linux guest on bare metal.
- [Running on HVF](../running-on-hvf.md) for the Apple Silicon development path.