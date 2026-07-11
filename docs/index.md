# nether

<div class="nether-tagline">the layer below</div>

A **type-2 hypervisor** in pure [Zig](https://ziglang.org). Modern guests only: no SeaBIOS, no IDE, no legacy chipset emulation. Runs beneath the guest on hardware-assisted virtualization (Apple Hypervisor.framework on aarch64, KVM on Linux/x86-64).

```
swerver (one binary, embeds nether) ──► HVF / KVM ──► microVM
              │
              ├── egress firewall + budgets (when net enabled)
              ├── control plane + virtio-vsock
              └── snapshot → COW fork (HVF only, ~10ms)
```

The standalone `nether` executable in this repo is a dev/bringup wrapper around the
embeddable core (`src/root.zig`). Production is swerver importing that library.

!!! warning "Building"
    nether is past Phase 3 on Apple Silicon (Linux boots, virtio works, snapshots fork). The x86/KVM platform layer is wired and **verified on metal** for PVH boot, control plane, vsock, and watchdogs; remaining KVM gaps are virtio-net bring-up, SMP, snapshot/restore, and GPU. See [Roadmap](roadmap.md) and [Limitations](about/limitations.md).

## What it does today

| Backend | Status |
| --- | --- |
| **HVF / aarch64** (lead) | Boots Alpine Linux to shell; full platform layer including snapshot-fork, egress firewall, control plane, metering, SMP, GPU |
| **KVM / x86-64** (reference) | PVH-boots Linux 6.12 to an interactive shell; virtio-blk R/W; userspace IOAPIC; control plane, vsock, metering, slirp egress firewall (when `net=1`); virtio-net enumerates but guest interface bring-up still failing on metal |

Without a kernel in the working directory, the binary runs a comptime smoke-test guest that prints over serial and shuts down cleanly. The message depends on the backend:

- **KVM** (x86 real-mode blob): `Nether lives. Phase 0: real-mode guest over COM1.`
- **HVF** (aarch64 MMIO UART): `Nether lives. Phase 0: aarch64 guest over MMIO UART.`

## Smoke test

```sh
zig build test
```

On a host that can **run** the built binary (Linux + KVM, or macOS + signed HVF build):

```sh
zig build run          # Linux/KVM (default x86_64-linux target)
# or on Apple Silicon:
DEVELOPER_DIR=/Library/Developer/CommandLineTools zig build -Dtarget=native run
codesign --sign - --entitlements nether.entitlements --force zig-out/bin/nether
```

KVM host with no `vmlinux` present:

```
Nether lives. Phase 0: real-mode guest over COM1.
[nether] guest shutdown.
```

## Where to next

<div class="grid cards" markdown>

- :material-download: **[Installation](getting-started/installation.md)**: Zig toolchain, backends, build and test.
- :material-server: **[Running on KVM](running-on-kvm.md)**: bare-metal or nested virt, PVH kernel, initramfs, virtio-blk.
- :material-apple: **[Running on HVF](running-on-hvf.md)**: Apple Silicon dev host, codesign, Alpine Linux boot.
- :material-package-variant: **[Provisioning base VMs](provisioning.md)**: image vs base, the declarative bake recipe, forking, and the re-bake/GC model.
- :material-shield-lock: **[Sandbox policy](guide/sandbox-policy.md)**: egress firewall, runtime budgets, metering.
- :material-map: **[Design](design.md)**: scope, security posture, prior art.
- :material-source-branch: **[Roadmap](roadmap.md)**: phases, platform track, what's next.
- :material-presentation: **[nether in one page](nether-for-execs.md)**: the non-technical why, in outcome language.

</div>