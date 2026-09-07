# Snapshot storage and bake fields

This reference describes the current **HVF NSNP v5** implementation and
`scripts/bake.py`. KVM NSKV snapshots use a separate implementation and are not
supported by these storage transforms. Recipes are TOML; Python 3.11+ is required.

## Recipe fields actually consumed

| Field | Current behavior |
| --- | --- |
| `snapshot.out` | Required destination; relative to the recipe directory |
| `snapshot.compress` | `none` (default) or `deflate`; other codecs are rejected |
| `snapshot.base` | A nonempty value is rejected for a durable base bake |
| `snapshot.kind` | Not consumed by the runner; bake always calls `__snapshot__` |
| `snapshot.sparse` | Not consumed by the runner; sparse writes are a VMM implementation detail |
| `snapshot.ttl_s` | Not consumed; park cleanup uses explicit GC CLI arguments |
| `disk.file` | Emits `disk=<path>`: persistent file-backed disk, outside the snapshot |
| `disk.size_mb` | Emits `disk_size_mb` only when `disk.file` is set |

Do not use unknown recipe fields as policy controls: the runner does not reject
all unrecognized keys.

```toml
[snapshot]
out = "base.snap"
compress = "deflate"  # optional; stored compressed, rehydrated before fork

[disk]
file = "/absolute/path/app.img"
size_mb = 64          # creation size for the persistent file
```

Without `disk.file`, the current HVF guest uses a 1 MiB ephemeral disk captured
in the snapshot. `disk.size_mb` alone does not resize that disk. With a file,
the HVF default creation size is 64 MiB; restore reopens the file rather than
capturing it. Forks using the same disk path share writes to that file.

Use absolute paths for external disks. The runner resolves image paths and
snapshot output relative to the recipe, but does not normalize every config
path. Its `fork` command writes a minimal restore config rather than replaying
the original recipe, so application-specific disk and network settings require
a configured launch flow.

## Compression

Sparse full snapshots preserve holes for zero RAM pages. Deflate compression
produces a storage artifact whose RAM cannot be mapped directly for COW restore.
`bake.py fork` first rehydrates it to `<snapshot>.hydrated`, reusing that file
while its mtime is at least as new as the compressed base. Rehydration cost is
separate from VM restore latency.

The native binary provides file-transform modes through `nether.conf`:

- `compress_in` / `compress_out`
- `rehydrate_in` / `rehydrate_out`
- `materialize_base` / `materialize_diff` / `materialize_out`

These are HVF file formats, not a common cross-backend interface. The codec is
deflate from Zig's standard library; zstd is not supported.

## Content-diff status

`SnapCtx.diff_base`, `writeRamDiff`, and `applyRamDiff` implement page
comparison and overlay helpers. HVF restore accepts a base path for diff
snapshots, and materialization folds a diff into a full image using filesystem
COW where available.

The control parser currently accepts a single capture path and **does not set
`SnapCtx.diff_base`**. Consequently, `__park__ file.snap base=base.snap` is
not a supported command. The helper tests do not establish an end-to-end
incremental park workflow.

Diff matching checks geometry, not the full identity of a same-sized base.
Retaining the correct base is the caller's responsibility.

## Manifests and retention

A bake manifest records schema 1, the recipe path, creation time, and hashes of
the binary, kernel, initramfs, and recipe bytes. It does not hash the contents of
every file referenced by `[[files]]`, or mutable disk contents. Changes to those
inputs may require `bake --force`.

A matching manifest and existing output produce a cache hit. Successful baking
reaps other `*.snap` files in the destination directory whose manifests name
the same recipe. This is directory/manifest cleanup, not live-VM lease tracking.

```sh
./scripts/bake.py gc --dir /path/to/bases
./scripts/bake.py gc --dir /path/to/bases --orphans
./scripts/bake.py gc --dir /path/to/parks --parks --ttl-s 3600 --dry-run
```

The first command deletes bases with a different recorded binary hash.
`--orphans` additionally deletes `*.snap` files without readable manifests.
Park GC recognizes the HVF park kind and compares file mtime with the explicit
TTL. Remove `--dry-run` to delete eligible parks. The caller must choose a TTL
that does not remove a snapshot still needed for resume.

HVF resume unlinks a consumed park snapshot. KVM has no matching kind/unlink
contract. Cleanup does not currently remove every auxiliary artifact, such as
a cached `.hydrated` file.
