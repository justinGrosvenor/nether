# Nether

A type-2 KVM-backed VMM in Zig. Modern guests only, no legacy hardware. Runs in
the layer below the guest, hence the name.

See [`docs/`](docs/README.md) for design, roadmap, and decisions.

## Status

**Phase 0 - KVM skeleton.** Creates a VM + vCPU, maps one guest RAM region, runs
a comptime-assembled real-mode blob that prints over COM1 via `KVM_EXIT_IO`, and
stops on `HLT`. The spine the rest of the roadmap hangs off.

## Build & run

Nether targets **Linux with `/dev/kvm`**. The build cross-compiles to
`x86_64-linux` by default, so it type-checks on any host; it can only *run* on a
Linux box with KVM and hardware virtualization enabled.

```sh
zig build              # cross-compile (x86_64-linux by default)
zig build run          # build + run (Linux host only)
zig build test         # run the test suite on the host
zig build -Dtarget=... # override the target
```

On a macOS host whose `xcode-select` points into Xcode.app (e.g. while doing iOS
work), native linking cannot find the SDK. Prefix any command that links a host
binary with the standalone Command Line Tools:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools zig build test
```

Cross-compilation is unaffected, so plain `zig build` (and `zig build -Dtarget=`)
still type-checks the Linux artifact without the prefix.

Expected output on a KVM host:

```
Nether lives. Phase 0: real-mode guest over COM1.
[nether] guest halted. Phase 0 complete.
```

## Layout

```
build.zig          cross-compiles x86_64-linux; tests build for the host
src/root.zig       library root the host (swerver) consumes
src/kvm.zig        hand-rolled KVM ABI: ioctl numbers, structs, wrapper
src/vm.zig         Vm + Vcpu: memory, the KVM_RUN loop, I/O dispatch
src/io.zig         Bus: port + MMIO device dispatch spine
src/memmap.zig     guest physical memory map (single source of truth)
src/serial.zig     minimal 16550 transmit device
src/main.zig       thin binary wrapper over the core
docs/              thesis.md · design.md · roadmap.md · decisions.md
```

Requires a recent Zig (developed against 0.16.0-dev).
