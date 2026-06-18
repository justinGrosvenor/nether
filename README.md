# Nether

A type-2 KVM-backed VMM in Zig. Modern guests only, no legacy hardware. Runs in
the layer below the guest, hence the name.

See [`docs/`](docs/README.md) for design, roadmap, and decisions.

## Status

**Phase 0 — KVM skeleton.** Creates a VM + vCPU, maps one guest RAM region, runs
a comptime-assembled real-mode blob that prints over COM1 via `KVM_EXIT_IO`, and
stops on `HLT`. The spine the rest of the roadmap hangs off.

## Build & run

Nether targets **Linux with `/dev/kvm`**. The build cross-compiles to
`x86_64-linux` by default, so it type-checks on any host; it can only *run* on a
Linux box with KVM and hardware virtualization enabled.

```sh
zig build              # cross-compile (x86_64-linux by default)
zig build run          # build + run (Linux host only)
zig build test         # ABI / struct-layout sanity checks
zig build -Dtarget=... # override the target
```

Expected output on a KVM host:

```
Nether lives — Phase 0: real-mode guest talking over COM1.
[nether] guest halted — Phase 0 complete
```

## Layout

```
build.zig          cross-compiles x86_64-linux by default; run/test steps
src/kvm.zig        hand-rolled KVM ABI: ioctl numbers, structs, ioctl wrapper
src/main.zig       VM/vCPU setup, the KVM_RUN loop, serial-OUT handling
docs/              design.md · roadmap.md · decisions.md
```

Requires a recent Zig (developed against 0.16.0-dev).
