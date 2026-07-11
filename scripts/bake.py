#!/usr/bin/env python3
# bake.py - reference runner for declarative nether base recipes.
#
# A base is a WARM memory snapshot: a booted guest driven to a running state (app up,
# caches hot) then frozen, so forks resume it in ~10 ms. That is different from a cold
# disk image (Packer/Docker/Ansible territory) - those build the filesystem; nether
# captures the running process. This runner owns only the warm layer:
#
#   bake:  boot a control-mode sandbox -> push files -> run warm-up -> wait until ready
#          -> __snapshot__ -> tear down, leaving <out> + <out>.manifest.json
#   fork:  restore a base into a fresh, driveable VM (~10 ms)
#   gc:    reap stale/superseded/orphaned bases (the manifest is the GC root), or with
#          --parks --ttl-s N, reap never-woken park snapshots older than N seconds
#
# A base is a DERIVED, build-specific cache keyed on (nether build, image, recipe): a base
# baked by one nether build is rejected by the next (validateHeader gates version + struct
# layout). `bake` is therefore idempotent - it re-bakes only when that key changes - and it
# GC's the generation it supersedes, so re-baking never silently accumulates dead full-RAM
# files.
#
# Recipe format (TOML - stdlib, no dependency, matching nether's zero-dep ethos):
#   see docs/provisioning.md for the annotated reference.
#
# Usage:
#   ./scripts/bake.py bake  base.nether.toml            # bake (or cache-hit) -> base.snap
#   ./scripts/bake.py fork  base.snap --name tenant-1   # restore a driveable fork
#   ./scripts/bake.py gc    [--dir bases] [--orphans]   # reap stale/superseded/orphaned bases
#   ./scripts/bake.py gc    --dir parks --parks --ttl-s 3600 [--dry-run]  # reap never-woken parks
#
# Boot/HVF paths need an Apple Silicon box; the recipe parse / manifest / GC logic is host
# independent (see the __main__ self-test: `./scripts/bake.py selftest`).
import os, sys, json, time, hashlib, socket, subprocess, shutil, glob, struct

try:
    import tomllib  # py3.11+ stdlib
except ModuleNotFoundError:
    tomllib = None

NB = os.environ.get("NETHER_ROOT") or os.path.expanduser("~/nether")
BIN = NB + "/zig-out/bin/nether"
MANIFEST_SCHEMA = 1
MAX_XFER = 16 * 1024 * 1024  # control.zig __put__ cap; larger files must not go via __put__

# Snapshot header (src/agent/snapshot.zig): 128-byte little-endian, magic 'NSNP', v5, KIND at 80.
SNAP_MAGIC = 0x4e534e50
SNAP_VERSION = 5
SNAP_HDR_SIZE = 128
SNAP_KIND_BASE = 0
SNAP_KIND_PARK = 1
RAM_FULL = 0
RAM_DIFF = 1
RAM_COMPRESSED = 2  # a stored/shipped base; rehydrate before forking

# --- hashing / manifest (host-independent: the GC root) ---------------------

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()

def nether_build_id():
    # The base is invalid across nether builds (validateHeader gates version + layout), so
    # the binary's own hash is the build key. Missing binary -> "unknown" (bake will fail
    # later at boot anyway, but gc must still run without a build present).
    return sha256_file(BIN) if os.path.exists(BIN) else "unknown"

def recipe_key(recipe_bytes, image):
    """The identity of a base: (nether build, image contents, recipe contents). Any change
    invalidates every base baked from the old key."""
    return {
        "nether_build": nether_build_id(),
        "kernel_sha": sha256_file(image["kernel"]),
        "initramfs_sha": sha256_file(image["initramfs"]) if image.get("initramfs") else None,
        "recipe_sha": sha256_bytes(recipe_bytes),
    }

def manifest_path(snap):
    return snap + ".manifest.json"

def write_manifest(snap, key, recipe_path, created):
    m = {"schema": MANIFEST_SCHEMA, "out": os.path.basename(snap), "recipe": recipe_path,
         "created": created, "key": key}
    with open(manifest_path(snap), "w") as f:
        json.dump(m, f, indent=2)
    return m

def read_manifest(snap):
    try:
        with open(manifest_path(snap)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None

def key_matches(manifest, key):
    return bool(manifest) and manifest.get("key") == key

# --- recipe parsing ---------------------------------------------------------

def load_recipe(path):
    if tomllib is None:
        die("Python 3.11+ required (stdlib tomllib) to parse recipes; you have %s" % sys.version.split()[0])
    with open(path, "rb") as f:
        raw = f.read()
    try:
        r = tomllib.loads(raw.decode())
    except Exception as e:
        die("recipe %s is not valid TOML: %s" % (path, e))
    # Resolve image paths relative to the recipe file, so a recipe is portable.
    base = os.path.dirname(os.path.abspath(path))
    img = r.get("image", {})
    for k in ("kernel", "initramfs"):
        if img.get(k) and not os.path.isabs(img[k]):
            img[k] = os.path.normpath(os.path.join(base, img[k]))
    r["image"] = img
    r["_dir"] = base
    return r, raw

def die(msg):
    print("bake: error: %s" % msg, file=sys.stderr)
    sys.exit(2)

def validate_recipe(r):
    img = r.get("image", {})
    if not img.get("kernel"):
        die("[image].kernel is required")
    if not os.path.exists(img["kernel"]):
        die("kernel not found: %s (run scripts/fetch-guest-image.sh?)" % img["kernel"])
    if img.get("initramfs") and not os.path.exists(img["initramfs"]):
        die("initramfs not found: %s" % img["initramfs"])
    snap = r.get("snapshot", {})
    if not snap.get("out"):
        die("[snapshot].out is required")
    # Storage policy (docs/incremental-snapshot-spec.md). Incremental (`base`) is gated on HVF
    # dirty-page tracking: parse it, but fail closed until the mechanism ships, so a recipe
    # can't silently produce a full snapshot when it asked for a delta.
    if snap.get("base"):
        die("[snapshot].base does not apply to a base bake. Per docs/incremental-snapshot-spec.md "
            "the content-diff is a __park__-only optimization (kind=park, the platform's parked-fork "
            "flow); a durable base (kind=base) always writes a full snapshot. Drop it; use sparse "
            "(on by default) for base size reduction.")
    comp = snap.get("compress", "none")
    if comp == "zstd":
        die('[snapshot].compress = "zstd" needs an external library nether deliberately avoids '
            '(zero-dependency, self-contained build). Use "deflate" (pure-Zig std.compress.flate, '
            "same CPU-for-disk trade on durable bases).")
    if comp not in ("none", "deflate"):
        die('[snapshot].compress must be "none" or "deflate"')
    # files: must fit the __put__ cap; large assets belong in the initramfs or a disk file.
    for f in r.get("files", []):
        h = f.get("host")
        if h and os.path.exists(h) and os.path.getsize(h) > MAX_XFER:
            die("file %s is %d bytes > MAX_XFER (%d): bake it into the initramfs or a "
                "file-backed disk instead of pushing it over the control socket"
                % (h, os.path.getsize(h), MAX_XFER))

# --- conf synthesis (recipe -> nether.conf) --------------------------------

def render_conf(r, control_socket, data_socket, restore_from=None):
    res = r.get("resources", {})
    lines = ["control_socket=%s" % control_socket, "data_socket=%s" % data_socket]
    if restore_from:
        lines += ["restore=1", "restore_from=%s" % restore_from]
    ready = r.get("ready", {})
    if ready.get("port"):
        lines.append("app_port=%d" % ready["port"])
    lines.append("ram_mb=%d" % res.get("ram_mb", 512))
    lines.append("cpus=%d" % res.get("cpus", 1))
    disk = r.get("disk", {})  # top-level [disk], per docs/incremental-snapshot-spec.md
    if disk.get("file"):  # file-backed: persistent, NOT captured in the snapshot, skips the eager read
        lines.append("disk=%s" % disk["file"])
        if disk.get("size_mb"):
            lines.append("disk_size_mb=%d" % disk["size_mb"])
    net = r.get("network", {})
    if net.get("egress") == "allow":
        lines.append("net_open=1")
    if net.get("egress") not in (None, "deny"):
        lines.append("net=1")
    if r.get("run_as"):
        lines.append("run_as=%s" % r["run_as"])
    return "\n".join(lines) + "\n"

# --- control-protocol client (mirrors fork_serve.py; proven pattern) --------

def uconn(path, to=20):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(to); s.connect(path); return s

def frame(s):
    b = b""
    while b"\x1e" not in b:
        c = s.recv(4096)
        if not c: break
        b += c
    return b

def cmd(s, line, to=30):
    old = s.gettimeout(); s.settimeout(to)
    s.sendall(line.encode() + b"\n"); r = frame(s).split(b"\x1e")[0].decode(errors="replace")
    s.settimeout(old); return r

def meta(s, line, to=120):
    old = s.gettimeout(); s.settimeout(to)
    s.sendall(line.encode() + b"\n"); b = b""
    while b"\n" not in b:
        c = s.recv(256)
        if not c: break
        b += c
    s.settimeout(old); return b.decode(errors="replace").strip()

def wait_sock(path, timeout=40):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if os.path.exists(path): return True
        time.sleep(0.0003)
    return False

def launch(cwd, log):
    f = open(os.path.join(cwd, log), "w")
    return subprocess.Popen([BIN], cwd=cwd, stdin=subprocess.DEVNULL, stdout=f, stderr=subprocess.STDOUT)

# --- bake -------------------------------------------------------------------

def do_bake(recipe_path, force=False, work=None):
    if not os.path.exists(BIN):
        die("%s not built (zig build -Dtarget=native && codesign ...)" % BIN)
    r, raw = load_recipe(recipe_path)
    validate_recipe(r)
    img = r["image"]
    snap = r["snapshot"]["out"]
    if not os.path.isabs(snap):
        snap = os.path.join(r["_dir"], snap)
    key = recipe_key(raw, img)

    # Idempotency: an up-to-date base (matching build + image + recipe) is a cache hit.
    if not force and os.path.exists(snap) and key_matches(read_manifest(snap), key):
        print("[bake] cache hit: %s is current (nether build + image + recipe unchanged)" % snap)
        return 0
    if os.path.exists(snap):
        print("[bake] superseding stale base %s (build/image/recipe changed)" % snap)

    work = work or os.environ.get("NETHER_WORK", "/tmp/nether-bake")
    shutil.rmtree(work, ignore_errors=True); os.makedirs(work)
    os.symlink(os.path.dirname(img["kernel"]), os.path.join(work, "kernels"))
    csock, dsock = "b.sock", "b.data"
    open(os.path.join(work, "nether.conf"), "w").write(render_conf(r, csock, dsock))

    proc = launch(work, "bake.log")
    try:
        if not wait_sock(os.path.join(work, csock)):
            die("base control socket never appeared (see %s/bake.log)" % work)
        s = uconn(os.path.join(work, csock)); cmd(s, "__info__")

        # 1. Push files (each <= MAX_XFER, checked in validate_recipe).
        for f in r.get("files", []):
            hp = f["host"] if os.path.isabs(f["host"]) else os.path.join(r["_dir"], f["host"])
            rep = cmd(s, "__put__ %s %s" % (hp, f["guest"]))
            print("[bake] put %s -> %s: %s" % (hp, f["guest"], rep.strip()))

        # 2. Warm-up steps, in order. `run` awaits completion; `start` launches a
        #    long-running process (backgrounded) and moves on.
        for step in r.get("warmup", []):
            if "run" in step:
                print("[bake] run: %s -> %s" % (step["run"], cmd(s, step["run"], 120).strip()[:80]))
            elif "start" in step:
                cmd(s, "%s >/tmp/bake-start.log 2>&1 &" % step["start"])
                print("[bake] start: %s (backgrounded)" % step["start"])

        # 3. Declared readiness gate (NOT a fixed sleep - a declared condition, polled
        #    finely). A port gate probes the app; a command gate runs until it succeeds.
        if not wait_ready(s, r.get("ready", {})):
            die("base never became ready (see the ready gate in %s)" % recipe_path)
        print("[bake] ready")

        # 4. Freeze. __snapshot__ quiesces, writes the COW-aligned base, and resumes.
        snap_name = os.path.basename(snap)
        rep = meta(s, "__snapshot__ %s" % snap_name)
        if "OK" not in rep:
            die("__snapshot__ failed: %s" % rep.strip())
        produced = os.path.join(work, snap_name)
        os.makedirs(os.path.dirname(snap) or ".", exist_ok=True)
        shutil.move(produced, snap)
        print("[bake] snapshot -> %s (%d bytes)" % (snap, os.path.getsize(snap)))
        if r["snapshot"].get("compress", "none") == "deflate":
            compress_base(snap)  # durable base: trade CPU for a smaller stored/shipped artifact

        try: meta(s, "__shutdown__", 5)
        except Exception: pass
    finally:
        try: proc.terminate()
        except Exception: pass
        time.sleep(0.3)
        try: proc.kill()
        except Exception: pass

    # 5. Manifest (the GC root) + reap superseded generations in the same dir.
    created = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    write_manifest(snap, key, os.path.abspath(recipe_path), created)
    reaped = gc_superseded(os.path.dirname(snap) or ".", keep=snap, recipe=os.path.abspath(recipe_path))
    if reaped:
        print("[bake] reaped %d superseded base(s): %s" % (len(reaped), ", ".join(reaped)))
    print("[bake] done. fork it:  ./scripts/bake.py fork %s --name tenant-1" % snap)
    return 0

def wait_ready(s, ready, timeout=60):
    t0 = time.time()
    if ready.get("command"):
        while time.time() - t0 < timeout:
            if "READY" in cmd(s, "%s && echo READY" % ready["command"], 10): return True
            time.sleep(0.05)
        return False
    if ready.get("port"):
        probe = "(exec 3<>/dev/tcp/127.0.0.1/%d) 2>/dev/null && echo READY" % ready["port"]
        while time.time() - t0 < timeout:
            if "READY" in cmd(s, probe, 10): return True
            time.sleep(0.05)
        return False
    # No declared gate: fall back to a short settle (discouraged - declare a gate).
    print("[bake] WARNING: no [ready] gate declared; using a 2s settle (declare port/command)")
    time.sleep(2.0)
    return True

# --- fork -------------------------------------------------------------------

def do_fork(snap, name, work=None):
    if not os.path.exists(snap):
        die("base not found: %s" % snap)
    m = read_manifest(snap)
    if m and m["key"].get("nether_build") not in (nether_build_id(), "unknown"):
        print("[fork] WARNING: base was baked by a different nether build; restore may be "
              "refused. Re-bake: ./scripts/bake.py bake %s" % m.get("recipe", "<recipe>"))
    forkable = ensure_forkable(os.path.abspath(snap))  # rehydrate a compressed base first (cached)
    work = work or os.path.join(os.environ.get("NETHER_WORK", "/tmp/nether-fork"), name)
    shutil.rmtree(work, ignore_errors=True); os.makedirs(work)
    kdir = os.path.join(NB, "kernels")
    if os.path.exists(kdir):
        os.symlink(kdir, os.path.join(work, "kernels"))
    open(os.path.join(work, "nether.conf"), "w").write(
        "restore=1\nrestore_from=%s\ncontrol_socket=f.sock\ndata_socket=f.data\n" % forkable)
    t0 = time.time()
    proc = launch(work, "fork.log")
    fsk = os.path.join(work, "f.sock")
    while not os.path.exists(fsk) and time.time() - t0 < 30:
        time.sleep(0.0003)
    driveable = None
    while time.time() - t0 < 30:
        try:
            s = uconn(fsk, 10); r = cmd(s, "__info__", 10)
            if r and "ERR" not in r: driveable = r; break
        except Exception: pass
        time.sleep(0.0003)
    dt = time.time() - t0
    print("[fork] %s driveable in %.3fs" % (name, dt))
    print("[fork] control: %s  data: %s  (pid %d)" % (fsk, os.path.join(work, "f.data"), proc.pid))
    return 0 if driveable else 1

# --- gc (manifest is the GC root) -------------------------------------------

def gc_superseded(bases_dir, keep, recipe):
    """Reap bases in `bases_dir` produced by the SAME recipe but a superseded generation
    (their manifest's key differs from the current one). `keep` is the just-written base."""
    keep = os.path.abspath(keep)
    reaped = []
    for snap in glob.glob(os.path.join(bases_dir, "*.snap")):
        if os.path.abspath(snap) == keep:
            continue
        m = read_manifest(snap)
        if not m:
            continue  # orphan (no manifest): only reaped by explicit `gc --orphans`
        if m.get("recipe") == recipe:
            # same recipe, but this base survived to here -> it is a superseded generation
            _reap(snap); reaped.append(os.path.basename(snap))
    return reaped

def do_gc(bases_dir, orphans=False):
    """Reap every base whose manifest key no longer matches the current nether build, plus
    (with --orphans) any .snap that has no manifest at all. The manifest is the GC root:
    a base no live manifest vouches for is garbage."""
    build = nether_build_id()
    reaped = []
    for snap in glob.glob(os.path.join(bases_dir, "*.snap")):
        m = read_manifest(snap)
        if m is None:
            if orphans:
                _reap(snap); reaped.append(os.path.basename(snap) + " (orphan: no manifest)")
            continue
        if m["key"].get("nether_build") not in (build, "unknown"):
            _reap(snap); reaped.append(os.path.basename(snap) + " (stale: older nether build)")
    if reaped:
        print("[gc] reaped %d:" % len(reaped)); [print("  - " + x) for x in reaped]
    else:
        print("[gc] nothing to reap in %s" % bases_dir)
    return 0

def _reap(snap):
    for p in (snap, manifest_path(snap)):
        try: os.remove(p)
        except OSError: pass

# --- orphan-park TTL reaper -------------------------------------------------
# A park snapshot is unlinked by the VMM the instant a fork wakes it (macRestore). One that is
# NEVER woken would otherwise linger at full size forever. `ttl_s` bounds that: reap park-kind
# snapshots older than the TTL. The GC class comes from the header KIND, so a base is never at
# risk; created_at is the file mtime (the VMM wrote the park then). Set the TTL well beyond the
# expected wake window so the reaper only ever touches an abandoned park, never a live one.

def read_snap_kind(path):
    """Return a valid v5 snapshot's KIND (0=base, 1=park), or None if `path` is not a recognizable
    snapshot of THIS format (too short, bad magic, wrong version). Fail safe: a file we cannot
    positively identify as a snapshot is never a reap candidate."""
    try:
        with open(path, "rb") as f:
            h = f.read(SNAP_HDR_SIZE)
    except OSError:
        return None
    if len(h) < SNAP_HDR_SIZE:
        return None
    magic, ver = struct.unpack_from("<I", h, 0)[0], struct.unpack_from("<I", h, 4)[0]
    if magic != SNAP_MAGIC or ver != SNAP_VERSION:
        return None
    return struct.unpack_from("<I", h, 80)[0]

def read_snap_encoding(path):
    """Return a valid v5 snapshot's RAM encoding (0=full, 1=diff, 2=compressed), or None if `path`
    is not a recognizable snapshot of this format. Used to decide whether a base must be rehydrated
    before it can be forked."""
    try:
        with open(path, "rb") as f:
            h = f.read(SNAP_HDR_SIZE)
    except OSError:
        return None
    if len(h) < SNAP_HDR_SIZE:
        return None
    if struct.unpack_from("<I", h, 0)[0] != SNAP_MAGIC or struct.unpack_from("<I", h, 4)[0] != SNAP_VERSION:
        return None
    return struct.unpack_from("<I", h, 84)[0]

def _nether_transform(key_in, key_out, src, dst):
    """Run a nether file-transform CLI mode (compress/rehydrate) in a scratch dir: it reads the
    key_in/key_out paths from nether.conf, does the transform, and exits (no VM). True on success."""
    import tempfile
    wd = tempfile.mkdtemp(prefix="nether-xf.")
    try:
        with open(os.path.join(wd, "nether.conf"), "w") as f:
            f.write("%s=%s\n%s=%s\n" % (key_in, os.path.abspath(src), key_out, os.path.abspath(dst)))
        r = subprocess.run([BIN], cwd=wd, capture_output=True, text=True, timeout=600)
        if r.returncode != 0:
            print("[bake] nether transform failed (rc=%d): %s%s" % (r.returncode, r.stdout, r.stderr))
        return r.returncode == 0
    finally:
        shutil.rmtree(wd, ignore_errors=True)

def compress_base(snap):
    """Deflate a full base's RAM region in place: the durable artifact keeps its name but becomes
    RAM_COMPRESSED (self-identifying), smaller to store and ship. do_fork rehydrates it on demand."""
    tmp = snap + ".ztmp"
    if not _nether_transform("compress_in", "compress_out", snap, tmp):
        die("compress failed for %s" % snap)
    before = os.path.getsize(snap); os.replace(tmp, snap)
    print("[bake] compressed base -> %s (%d -> %d bytes, %.1f%%)" %
          (snap, before, os.path.getsize(snap), 100.0 * os.path.getsize(snap) / before))

def ensure_forkable(snap):
    """A compressed base cannot be COW-mmap'd, so it is not directly forkable. Rehydrate it to a
    full, sparse, fast-forkable base cached next to it (<base>.hydrated, reused while newer than the
    base) and return that path. A full base is returned unchanged -> the fast fork path is intact."""
    if read_snap_encoding(snap) != RAM_COMPRESSED:
        return snap
    hy = snap + ".hydrated"
    if not (os.path.exists(hy) and os.path.getmtime(hy) >= os.path.getmtime(snap)):
        print("[fork] rehydrating compressed base -> %s (once per host; forks stay ~10ms)" % hy)
        if not _nether_transform("rehydrate_in", "rehydrate_out", snap, hy):
            die("rehydrate failed for %s" % snap)
    return hy

def reap_parks(parks_dir, ttl_s, dry_run=False, now=None):
    """Reap park-kind snapshots in `parks_dir` whose age (now - mtime) exceeds `ttl_s`. Only files
    whose header positively identifies a PARK of this format are touched; bases, non-snapshots, and
    truncated/corrupt files are left alone. Returns [(basename, age_s), ...] reaped (or, dry-run,
    that would be). `now` is injectable for tests."""
    now = time.time() if now is None else now
    reaped = []
    for snap in sorted(glob.glob(os.path.join(parks_dir, "*.snap"))):
        if read_snap_kind(snap) != SNAP_KIND_PARK:
            continue  # not a park (base / unrecognized) -> not this reaper's business
        try:
            age = now - os.path.getmtime(snap)
        except OSError:
            continue
        if age <= ttl_s:
            continue  # still within its wake window
        reaped.append((os.path.basename(snap), int(age)))
        if not dry_run:
            _reap(snap)
    return reaped

# --- self-test (host-independent: parsing + manifest + GC) ------------------

def selftest():
    import tempfile
    d = tempfile.mkdtemp(prefix="bake-selftest.")
    ok = True
    def check(name, cond):
        nonlocal ok
        print("  %s %s" % ("PASS" if cond else "FAIL", name)); ok = ok and cond
    # manifest round-trip + key match
    snap = os.path.join(d, "a.snap"); open(snap, "wb").write(b"x")
    key = {"nether_build": "b1", "kernel_sha": "k", "initramfs_sha": None, "recipe_sha": "r"}
    write_manifest(snap, key, "/r.toml", "t")
    check("manifest round-trips", read_manifest(snap)["key"] == key)
    check("key_matches is exact", key_matches(read_manifest(snap), key) and
          not key_matches(read_manifest(snap), {**key, "recipe_sha": "r2"}))
    # gc_superseded reaps a same-recipe older base, keeps the current one
    old = os.path.join(d, "old.snap"); open(old, "wb").write(b"y")
    write_manifest(old, {**key, "nether_build": "b0"}, "/r.toml", "t0")
    reaped = gc_superseded(d, keep=snap, recipe="/r.toml")
    check("gc_superseded reaps the old generation", "old.snap" in reaped)
    check("gc_superseded keeps the current base", os.path.exists(snap))
    check("gc_superseded removed old manifest too", not os.path.exists(manifest_path(old)))
    # orphan handling: a .snap with no manifest survives default gc, dies under --orphans
    orph = os.path.join(d, "orph.snap"); open(orph, "wb").write(b"z")
    gc_superseded(d, keep=snap, recipe="/r.toml")
    check("orphan survives implicit gc", os.path.exists(orph))
    # park reaper: an expired park is reaped by KIND + age; a base and a fresh park survive, and a
    # non-snapshot file is never touched. Ages are baked into mtime so the test needs no sleeping.
    pd = os.path.join(d, "parks"); os.makedirs(pd)
    def wsnap(name, kind, age_s):
        p = os.path.join(pd, name)
        h = bytearray(SNAP_HDR_SIZE)
        struct.pack_into("<I", h, 0, SNAP_MAGIC); struct.pack_into("<I", h, 4, SNAP_VERSION)
        struct.pack_into("<I", h, 80, kind)
        open(p, "wb").write(bytes(h))
        t = time.time() - age_s; os.utime(p, (t, t))
        return p
    old_park = wsnap("old.park.snap", SNAP_KIND_PARK, 10_000)
    new_park = wsnap("new.park.snap", SNAP_KIND_PARK, 5)
    a_base   = wsnap("keep.base.snap", SNAP_KIND_BASE, 10_000)  # old, but a base -> never a park reap
    junk = os.path.join(pd, "junk.snap"); open(junk, "wb").write(b"not a snapshot header")
    names = [n for n, _ in reap_parks(pd, ttl_s=3600)]
    check("reaper reaps the expired park", "old.park.snap" in names and not os.path.exists(old_park))
    check("reaper spares a fresh park", "new.park.snap" not in names and os.path.exists(new_park))
    check("reaper never reaps a base", os.path.exists(a_base))
    check("reaper ignores a non-snapshot file", os.path.exists(junk))
    check("reaper dry-run removes nothing",
          [n for n, _ in reap_parks(pd, ttl_s=1, dry_run=True)] and os.path.exists(new_park))
    # compress plumbing (host-independent parts): encoding read + ensure_forkable short-circuit.
    def wsnap2(name, encoding):
        p = os.path.join(pd, name); h = bytearray(SNAP_HDR_SIZE)
        struct.pack_into("<I", h, 0, SNAP_MAGIC); struct.pack_into("<I", h, 4, SNAP_VERSION)
        struct.pack_into("<I", h, 84, encoding)
        open(p, "wb").write(bytes(h)); return p
    full = wsnap2("full.base.snap", RAM_FULL); comp = wsnap2("comp.base.snap", RAM_COMPRESSED)
    check("read_snap_encoding reads a full base", read_snap_encoding(full) == RAM_FULL)
    check("read_snap_encoding reads a compressed base", read_snap_encoding(comp) == RAM_COMPRESSED)
    check("ensure_forkable passes a full base through (no rehydrate)", ensure_forkable(full) == full)
    shutil.rmtree(d, ignore_errors=True)
    print("selftest:", "OK" if ok else "FAILED")
    return 0 if ok else 1

# --- cli --------------------------------------------------------------------

def main(argv):
    if not argv:
        print("usage: bake.py {bake <recipe>|fork <snap> --name N|"
              "gc [--dir D] [--orphans] | gc --dir D --parks --ttl-s N [--dry-run]|selftest}")
        return 2
    cmd0 = argv[0]
    if cmd0 == "bake":
        if len(argv) < 2: die("bake needs a recipe path")
        return do_bake(argv[1], force="--force" in argv)
    if cmd0 == "fork":
        if len(argv) < 2: die("fork needs a base snapshot path")
        name = argv[argv.index("--name") + 1] if "--name" in argv else "fork"
        return do_fork(argv[1], name)
    if cmd0 == "gc":
        d = argv[argv.index("--dir") + 1] if "--dir" in argv else "."
        if "--parks" in argv:
            if "--ttl-s" not in argv: die("gc --parks needs --ttl-s <seconds>")
            ttl = int(argv[argv.index("--ttl-s") + 1])
            dry = "--dry-run" in argv
            reaped = reap_parks(d, ttl, dry_run=dry)
            if reaped:
                print("[gc] %s %d orphan park(s) older than %ds in %s:" %
                      ("would reap" if dry else "reaped", len(reaped), ttl, d))
                for name, age in reaped: print("  - %s (age %ds)" % (name, age))
            else:
                print("[gc] no orphan parks older than %ds in %s" % (ttl, d))
            return 0
        return do_gc(d, orphans="--orphans" in argv)
    if cmd0 == "selftest":
        return selftest()
    die("unknown command: %s" % cmd0)

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
