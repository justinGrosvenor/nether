# nether

<div class="nether-tagline">the layer below</div>

A **type-2 hypervisor** in pure [Zig](https://ziglang.org). Modern guests only: no SeaBIOS, no IDE, no legacy chipset emulation. Runs beneath the guest on hardware-assisted virtualization (KVM on Linux/x86-64, Apple Hypervisor.framework on aarch64).

```
host (swerver) ──► nether ──► KVM / HVF ──► microVM
                      │
                      ├── snapshot → COW fork (~90ms)
                      ├── egress firewall + budgets
                      └── virtio-vsock spine
```

!!! warning "Building"
    nether is past Phase 3 on Apple Silicon (Linux boots, virtio works, snapshots fork). The x86/KVM platform layer is catching up. See [Roadmap](roadmap.md) and [Limitations](about/limitations.md).

## What it does today

| Backend | Status |
| --- | --- |
| **KVM / x86-64** | PVH-boots Linux 6.12 to an interactive shell; virtio-blk R/W; userspace IOAPIC |
| **HVF / aarch64** | Boots Alpine Linux to shell; control plane, metering, snapshot-fork, egress firewall |

Without a kernel in the working directory, the binary runs a comptime smoke-test guest that prints over serial and shuts down cleanly.

## Smoke test

```sh
zig build test
zig build run
```

On a KVM host with no `vmlinux` present:

```
Nether lives. Phase 0: real-mode guest over COM1.
[nether] guest shutdown.
```

## Where to next

<div class="grid cards" markdown>

- :material-download: **[Installation](getting-started/installation.md)**: Zig toolchain, backends, build and test.
- :material-server: **[Running on KVM](running-on-kvm.md)**: bare-metal or nested virt, PVH kernel, initramfs, virtio-blk.
- :material-apple: **[Running on HVF](running-on-hvf.md)**: Apple Silicon dev host, codesign, Alpine Linux boot.
- :material-shield-lock: **[Sandbox policy](guide/sandbox-policy.md)**: egress firewall, runtime budgets, metering.
- :material-map: **[Design](design.md)**: scope, security posture, prior art.
- :material-source-branch: **[Roadmap](roadmap.md)**: phases, platform track, what's next.

</div>