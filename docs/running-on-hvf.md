# Running Nether on Apple HVF (macOS / aarch64)

On an Apple Silicon Mac, Nether's HVF backend (Apple's Hypervisor.framework) runs
**aarch64** guests natively - no remote box, no Linux. This is the dev-host path;
the Linux/KVM/x86-64 path is in [running-on-kvm.md](running-on-kvm.md). The
backend is chosen at compile time from the host OS (see
[decisions.md](decisions.md) D9), so the same source tree builds either way.

## 0. Requirements

- Apple Silicon (M-series) Mac. HVF virtualizes the host architecture, so guests
  are aarch64 (not x86-64).
- The Command Line Tools SDK (for Hypervisor.framework and libSystem):
  `xcode-select --install` if needed.
- Zig 0.16.0 (see [running-on-kvm.md](running-on-kvm.md) step 1; the same pinned
  toolchain).

## 1. Build, sign, run

The HVF backend is selected automatically when the target is macOS. Build
natively, codesign with the hypervisor entitlement, then run:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools zig build -Dtarget=native
codesign --sign - --entitlements nether.entitlements --force zig-out/bin/nether
./zig-out/bin/nether
```

`com.apple.security.hypervisor` is a restricted entitlement, but **ad-hoc signing
(`--sign -`) works for running locally** - no paid Apple Developer account or
provisioning profile is needed on your own machine. Re-sign after every rebuild
(the binary's signature is replaced).

Expected output (the current first-light milestone): a tiny aarch64 guest that
prints over an MMIO UART and powers off.

```
Nether lives. Phase 0: aarch64 guest over MMIO UART.

[nether] guest shutdown.
```

## What works today, and what's next

First light proves the HVF substrate end to end: `hv_vm_create` + `hv_vm_map`
(guest RAM at the standard arm64 `virt` base `0x4000_0000`), `hv_vcpu_create`, the
`hv_vcpu_run` loop, and the data-abort (ESR_EL2) decode that turns a guest MMIO
access into a `Bus` dispatch (the same device bus the x86 path uses). A guest
signals stop with a write to a poweroff sentinel (PSCI replaces this with the
substrate).

Still to come on the aarch64 track (see [roadmap.md](roadmap.md)): the framework
GIC (`hv_gic`), a PL011 UART, the ARM generic timer, PSCI for power, an
`Image`+DTB Linux boot path, and then the virtio devices (reusing the datapath,
with MSI via the GIC ITS).

## Notes

- The guest blob is position-independent (absolute MOVZ immediates) and loaded at
  `0x4000_0000`; after writing guest code through the host mapping we call
  `sys_icache_invalidate`, since host data writes are not I-cache coherent with
  the guest core on Apple Silicon.
- `zig build run` is not wired for the codesign step; run the signed binary
  directly as above. (Cross-compiling the Linux artifact with `zig build` is
  unaffected and needs no signing.)
