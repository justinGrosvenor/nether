# Provisioning base VMs

An image supplies the kernel and guest filesystem. A base is a snapshot of that
image after boot and application warm-up. The current `scripts/bake.py` runner
targets **HVF on Apple Silicon** and requires **Python 3.11+**.

## Prepare and bake

From the Nether checkout:

```sh
zig build -Dtarget=native
./scripts/fetch-guest-image.sh
# The fetch script does not retain its temporary rootfs tree.
if [ ! -d kernels/rootfs ]; then
  mkdir -p kernels/rootfs
  (cd kernels/rootfs && gzip -dc ../initramfs.cpio.gz | cpio -idm)
fi
./tools/build-guest-aarch64-runtimes.sh
export NETHER_ROOT="$(pwd)"
./scripts/bake.py bake examples/base.nether.toml
./scripts/bake.py fork examples/base.snap --name tenant-1
```

The runtime-image helper requires Docker and adds Python, SQLite, and Node by
default. The example starts Python's HTTP server before capture. Runtime-image
building and a live bake were not rerun in the 2026-09-06 documentation audit.

The runner defaults to `~/nether/zig-out/bin/nether`; `NETHER_ROOT` changes
the checkout root. It recreates its scratch directory before a bake
(default `/tmp/nether-bake`) or named fork (under `/tmp/nether-fork`).
`NETHER_WORK` changes those work roots. Use dedicated work directories:
existing contents there are removed.

A successful fork leaves a VM process running and prints its PID, control/data
sockets, and driveable latency. The runner is not a persistent pool supervisor.
Use the control protocol or a process manager to shut the VM down.

## Consumed recipe fields

| Field | Current behavior |
| --- | --- |
| `image.kernel`, `image.initramfs` | Paths resolve relative to the recipe and participate in the cache key |
| `resources.ram_mb`, `resources.cpus` | Default 512 MiB / 1 vCPU |
| Top-level `run_as` | Emits the HVF guest-agent user setting; place it before TOML tables |
| `network.egress` | `deny`/omitted leaves NIC off; `allow` enables networking with firewall disabled |
| `files[].host`, `files[].guest` | Passes a host-to-guest file transfer command; see restrictions below |
| `warmup[].run` | Executes a guest command and waits for its reply |
| `warmup[].start` | Backgrounds a guest command, logging to `/tmp/bake-start.log` |
| `ready.command` | Polls a command with an appended success marker |
| `ready.port` | Polls using the guest shell's `/dev/tcp` support |
| `snapshot.out` | Required; relative to the recipe directory |
| `snapshot.compress` | `none` or `deflate` |

The runner symlinks the kernel's **directory** as `kernels/`; Nether then opens
`kernels/Image` and `kernels/initramfs.cpio.gz`. Use that exact layout.
Selecting a differently named image file in the recipe does not make the runner
stage it under those names.

An arbitrary `network.egress` string is not parsed as a firewall policy: values
other than `deny` enable `net=1`, and only `allow` also emits `net_open=1`.
Use explicit Nether config for CIDR rules. Disk and storage fields are described
in [snapshot storage](incremental-snapshot-spec.md).

## Readiness and transfer limits

When both readiness fields exist, `ready.command` wins. With neither, the
runner warns and sleeps two seconds. A port gate needs shell `/dev/tcp`
support; use a command appropriate to the guest instead. The example uses Python
to connect to its server.

Warm-up and transfer replies are printed, but the runner does not uniformly
validate every guest exit code. Make readiness test the resulting application
state.

`__put__` is limited to a regular file of at most 16 MiB, and Nether confines
host transfer paths to its launch-directory jail. The runner resolves a host
path relative to the recipe but does not copy that file into its scratch jail.
A file elsewhere in the checkout is therefore not automatically transferable.
Bake application files into the image or stage them through a custom launch
flow; the example avoids this unresolved staging seam.

## Cache identity and launch settings

A manifest hashes the binary, kernel, initramfs, and recipe bytes. A matching
manifest plus output is a cache hit. The contents of separately referenced files
and persistent disks are not included. Use `bake --force` when those change.

Rebuild-dependent layout changes can make an old base unrestorable. Rebake
after changing Nether. `fork` warns on a recorded binary-hash mismatch; it
does not reject every different build itself. See [versioning](versioning.md).

The fork runner emits only restore and control/data-socket settings; it does
not replay the recipe's full host configuration. Persistent disks, networking,
and custom policy need a configured fork launch. Guest state already in the
snapshot, including its boot-time agent settings, is inherited.

Bakes should contain generic application state. Per-tenant credentials and
mutable external resources require explicit ownership. COW RAM does not make
a shared disk file or external connection private.

See [snapshot storage](incremental-snapshot-spec.md) for compression,
content-diff status, and the exact GC behavior.
