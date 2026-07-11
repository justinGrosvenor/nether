# Provisioning base VMs

A **base** is the thing you fork. This page is the path from nothing to a base you can
fork in ~10 ms, for someone who knows VMs and wants to not fight the tool.

## The mental model: two layers, two tools

Provisioning splits cleanly, and conflating the two is the main way people get confused:

| Layer | What it is | Built with | Changes |
| --- | --- | --- | --- |
| **Image** | the guest's *filesystem*: kernel + rootfs, your runtimes, your app binary | anything that makes a rootfs: a Dockerfile you export, Packer, Ansible, or `scripts/fetch-guest-image.sh` | rarely |
| **Base** | a *warm memory snapshot*: the guest booted and driven to a running state (app up, caches hot), then frozen | `nether bake` (this is the nether-native part) | often |

The image is what the guest *can* do. The base is the *running state* you clone. Packer and
Ansible build cold disk images; they cannot capture "python loaded, server accepting, caches
hot, frozen at this instant." That warm capture is the only part nether owns. Build the image
with whatever you already use; let nether own the freeze.

## The path

```sh
# 0. Image (once per capability set): produce kernels/Image + kernels/initramfs.cpio.gz
./scripts/fetch-guest-image.sh          # or bring your own rootfs

# 1. Write a recipe (see examples/base.nether.toml)

# 2. Bake: boot -> push files -> warm-up -> wait ready -> snapshot -> tear down
./scripts/bake.py bake base.nether.toml   # -> base.snap (+ base.snap.manifest.json)

# 3. Fork per tenant: restore a driveable VM in ~10 ms
./scripts/bake.py fork base.snap --name tenant-1
```

`bake.py` is a reference runner over the control protocol your own orchestrator can drive
directly; the declarative recipe is the ergonomic front door.

## The recipe

The recipe is TOML (stdlib, no dependency, matching nether's zero-dep build). The annotated
example is [`examples/base.nether.toml`](../examples/base.nether.toml); the fields:

- **`[image]`** `kernel`, `initramfs`: the capability layer. Paths resolve relative to the
  recipe file.
- **`[resources]`** `ram_mb`, `cpus`.
- **`[disk]`** (top-level) the one storage decision that matters at bake time. Exactly one of:
  - `size_mb` (in-memory): **captured** in the snapshot, COW-forked, adds directly to snapshot
    size.
  - `file` (file-backed): **not captured**, persistent on its own, and it skips the eager read
    on restore (so it is also the faster-restore choice for large disks).
- **`[network]`** `egress`: `deny` (safe default) | `allow` | a policy.
- **`run_as`**: run guest commands as a non-root user.
- **`[[files]]`** `host`/`guest`: your code, pushed over the control socket before warm-up.
  Each file must be **≤ 16 MiB** (the `__put__` cap); the runner refuses an oversize file.
  Route large assets (models, `node_modules`) into the initramfs or a file-backed disk.
- **`[[warmup]]`** ordered steps: `run` awaits completion, `start` launches a long-running
  process and moves on.
- **`[ready]`** the readiness gate: `port` or `command`. A *declared condition, polled
  finely*, not a fixed sleep. (Fixed sleeps are how you get latency numbers wrong by 5x.)
- **`[snapshot]`** `out`, `kind = "base"`, plus a storage-policy block defined in
  [`docs/incremental-snapshot-spec.md`](incremental-snapshot-spec.md): `sparse` (zero pages
  as holes; near-free, default on), `compress` (`"none"`/`"zstd"`; note zstd trades disk for
  CPU *and forfeits the ~10 ms lazy restore*, since a compressed RAM region can't be COW-mmap'd,
  so it's bases-only), `base` (incremental delta, **gated** on HVF dirty-page tracking; the
  runner rejects it until the mechanism ships), and `ttl_s` (retention). The recipe is where
  storage *policy* lives; the VMM implements the *mechanism*.

## The base is a cache, not an artifact you ship

This is the one thing that surprises people. A base is **build-specific**: `validateHeader`
gates the snapshot on the exact nether version + struct layout + native endianness, so a
base baked by one nether build is *refused* by the next. A base is therefore a derived,
host-local cache keyed on **(nether build, image, recipe)**, not a portable image.

`bake` handles this for you:

- **Idempotent.** If `base.snap` and its manifest already match the current build + image +
  recipe, `bake` is a cache hit and does nothing. Change any of the three and it re-bakes.
- **Self-GC'ing.** The manifest (`base.snap.manifest.json`) is the garbage-collection root.
  When `bake` supersedes a base, it reaps the generation it replaced, so idempotent re-bakes
  never silently accumulate dead full-size snapshots. `bake.py gc [--dir bases] [--orphans]`
  reaps bases left by an older nether build, and (with `--orphans`) snapshots with no
  manifest at all. A base no live manifest vouches for is garbage.

Practical consequence: after you rebuild nether, re-run `bake` (it re-bakes and reaps), or a
`fork` of a stale base will be refused. `fork` warns when a base's manifest predates the
current build.

## Gotchas checklist

- **Control mode is required for a driveable fork.** The recipe boots the bake sandbox with
  a `control_socket`; a snapshot taken without one yields console+blk-only forks. `bake`
  always does this correctly; if you drive the protocol yourself, don't skip it.
- **The base holds no per-tenant state.** Bake the *generic* warm state (app up, caches
  hot); specialize per tenant *after* the fork. A fork inherits everything the base had open.
- **Same host, same build.** Bases don't travel across nether versions or (in practice)
  hosts. Regenerate, don't ship.
- **Warm-up runs in the guest.** Your app must already be reachable in the guest (baked into
  the image, mounted from a disk file, or `[[files]]`-pushed) before `[[warmup]]` can run it.
