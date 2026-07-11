# Snapshot storage config fields — spec for the bake recipe

Scope: the config fields that govern snapshot **storage** (size, incremental/diff, retention).
For the recipe/runner author. TOML here; maps 1:1 to the YAML recipe's `[snapshot]`/`[disk]`
blocks and to `nether.conf` keys the runner writes. Reserve the *shape* now even where the
mechanism lands later — so the format doesn't break when storage features ship.

Dependency flags: **[U]** = unconditional (no hypervisor support needed, safe to build now).
**[D]** = needs HVF dirty-page tracking; treat as gated until the research confirms the API
exists on Apple Silicon. If [D] is unavailable, `[U]` (sparse + dedup) is the full fallback.

## `[snapshot]`

```toml
[snapshot]
out      = "base.snap"     # output path (runner opens via the jail-root dirfd)
kind     = "base"          # "base" | "park"
sparse   = true            # [U] write zero pages as filesystem holes (SEEK_HOLE/hole-punch)
compress = "none"          # [U] "none" | "zstd" — compress the RAM region only
base     = ""              # [U] incremental: path of the base this is a delta of (content-diff, shipped)
ttl_s    = 0               # retention: 0 = none; >0 = reap if unconsumed after N seconds
```

Field semantics:

- **`kind`** — the lifecycle contract, already in the VMM (`SNAP_KIND_BASE`/`SNAP_KIND_PARK`).
  `base` = durable, forked many, retained until superseded. `park` = one-shot, `unlink`ed by
  `macRestore` the instant the guest resumes. This field is the GC class (see Retention).
- **`sparse`** *(default true)* **[U]** — do not write runs of zero pages; leave holes. A mostly
  -idle guest's RAM is largely zero, so this alone shrinks a typical base severalfold at ~no
  CPU. Restore is unaffected (COW-mmap of a sparse file reads holes as zero). Make it the
  default; it is close to free.
- **`compress`** *(default "none")* **[U]** — zstd the RAM region. Trades CPU for disk. Sensible
  for durable `base` snapshots (baked once, read many); usually *not* worth it for `park`
  (latency-sensitive, written on the hot path). A compressed RAM region **cannot be COW-mmap'd
  directly** — restore must decompress into an anonymous mapping, which forfeits the ~10 ms lazy
  restore. So: `compress` and lazy-COW-restore are mutually exclusive; document that a compressed
  base trades fork latency for disk. Keep default `none`.
- **`base`** *(default "")* **[U via content-diff]** — incremental/diff snapshot. When set, store
  only the guest pages that **diverged** from `base`. Restore COW-maps `base` and overlays the
  diff. Elegant win for `park`: a parked fork usually dirties a tiny fraction of RAM, so the delta
  is small AND cheap to reap.
  MECHANISM (decided by research): HVF has **no dirty-page log** (unlike KVM, which is how
  Firecracker does diff snapshots), only `hv_vm_protect` write-protect. So do NOT build
  write-protect+fault tracking. Instead, since `__park__` is a stop-the-world capture and the fork
  still holds the base file it COW-mapped, **`memcmp` each guest RAM page against the base file at
  park time and store only differing pages + offsets.** No hypervisor dependency, no per-write
  fault overhead — just an O(RAM) scan off the hot path (guest already quiesced). Restore reads
  the base + overlays the diff pages. `base` should default to the `restore_from` path the fork
  came from.
- **`ttl_s`** *(default 0)* — retention bound for transient snapshots. `park` with `ttl_s>0` is
  reaped if it is never consumed within the window (the never-woken-park orphan). The runner/
  platform owns the reaper; the VMM just records `created_at` in the manifest.

## `[disk]` — storage-visible by design

```toml
[disk]
size_mb = 256              # in-memory: captured IN the snapshot (+size_mb to the file) + COW-forked
# --- OR ---
file    = "app.img"        # file-backed: persistent, NOT captured, skips the eager restore read
```

`size_mb` (in-memory) **adds directly to snapshot size** and is captured/forked with RAM.
`file` (file-backed) lives outside the snapshot (persistent, shared), so the snapshot is smaller
and the fork skips reading it (this is why file-backed forks are the fast path). Exactly one of
the two. Surface the tradeoff in the doc: in-memory = self-contained + captured; file-backed =
persistent + lean snapshot.

## Retention / GC (the manifest is the GC root)

`bake` writes a manifest alongside `out` hashing `(nether build id, image digests, recipe hash)`.
Rules the runner enforces:

1. **Idempotent bake** — manifest matches current build+image+recipe → cache hit, skip.
2. **Supersede-and-reap** — a re-bake (drift) writes the new base, then **deletes the base it
   supersedes**. A base file with no live manifest reference is garbage. This is the orphan
   source the ergonomic re-bake introduces; `bake` must own it.
3. **Transient bound** — `park` snapshots are `unlink`ed on wake by the VMM; `ttl_s` bounds the
   never-woken case. GC class comes from `kind`.

Model to mirror: **containerd leases** (a snapshot is retained only while something leases it;
unleased + past-TTL = collectible) — the cleanest "delete what nothing references, bound the
transient" shape. (The pending research will confirm this vs refcounting/mark-sweep.)

## Capture interface — the seam between the protocol and the mechanism

The `__snapshot__`/`__park__` handler (protocol side, other tab) and the capture mechanism
(`captureImpl`, this tab) meet at **one field on `SnapCtx`**:

```
diff_base: ?[*:0]const u8 = null   // set by the handler from a validated base= path; null = full snapshot
```

- Handler: parse `base=<path>` per the protocol section, resolve it with `jailedPath`+`openJailedAt`
  (same-uid input, jail-TOCTOU), then set `ctx.diff_base` to the resolved path before invoking the
  existing `snapshotCall`/`parkCall`. Unknown keys / whitespace -> ERR (strict-arg). Do NOT change
  the `Snapshotter` func-pointer signature; set the field.
- Mechanism (mine): if `ctx.diff_base != null` AND `kind == PARK` AND the base's RAM geometry matches,
  `captureImpl` content-diffs (memcmp vs the base file at capture) and writes the diff encoding;
  otherwise it writes a full (sparse) snapshot. So `base=` on a base-kind capture, or against a
  size-mismatched base, silently *and correctly* degrades to a full snapshot — the runner's gate
  still holds because the reply distinguishes nothing the runner relies on (it gets a valid snapshot
  either way; the size win is best-effort).

RESTORE side: the wake supplies the base via conf `base=<path>` (boot-time, not a control command);
`macRestore` maps the base COW and overlays the diff. A diff snapshot with no base at wake -> fail
closed. (Format carries a base-size fingerprint for a cheap sanity check; a wrong same-size base is
the platform's responsibility, consistent with the lease/GC model.)

## Status

- Shipped (**[U]**, no hypervisor dependency): `sparse` (default on, `snapshot: sparse RAM writes`),
  and `base` incremental/diff snapshots via **content-diff** (`snapshot: content-diff parks`, format
  v5). The research resolved the open question: **Apple HVF exposes no dirty-page log**, so diff is
  done by `memcmp` vs the base at park time (guest quiesced, off the hot path) rather than
  write-protect+fault tracking. The mechanism is unit-verified (writeRamDiff/applyRamDiff round-trip,
  header validation, fuzz); the remaining seam is the control-plane `base=` parse that sets
  `SnapCtx.diff_base` (see Capture interface above).
- Shipped (**[U]**, runner-side): the manifest + idempotent bake + supersede-reap (`bake.py`),
  `clonefile` base dedup (`materializeDiff` + `materialize_*` conf: a content-diff folds into a
  standalone base sharing the base's blocks copy-on-write), and the `ttl_s` orphan-park reaper
  (`bake.py gc --parks --ttl-s N`: reaps never-woken park-kind snapshots past their age, keyed on
  the header KIND with the file mtime as created_at; bases are never at risk).
- Not yet built (**[U]**): `compress` (opt-in, bases only). Does not need hypervisor support.
