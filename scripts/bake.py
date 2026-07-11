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
#   gc:    reap stale/superseded/orphaned bases (the manifest is the GC root)
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
#
# Boot/HVF paths need an Apple Silicon box; the recipe parse / manifest / GC logic is host
# independent (see the __main__ self-test: `./scripts/bake.py selftest`).
import os, sys, json, time, hashlib, socket, subprocess, shutil, glob

try:
    import tomllib  # py3.11+ stdlib
except ModuleNotFoundError:
    tomllib = None

NB = os.environ.get("NETHER_ROOT") or os.path.expanduser("~/nether")
BIN = NB + "/zig-out/bin/nether"
MANIFEST_SCHEMA = 1
MAX_XFER = 16 * 1024 * 1024  # control.zig __put__ cap; larger files must not go via __put__

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
        die("[snapshot].base (incremental/diff) is decided but not yet implemented. HVF has no "
            "dirty-page log, so the mechanism is a content-diff (memcmp guest RAM against the base "
            "at park time, off the hot path), landing with the incremental-snapshot work. Rejected "
            "until the VMM __snapshot__ path accepts it; use sparse instead, or drop it for a full base.")
    if snap.get("compress", "none") not in ("none", "zstd"):
        die('[snapshot].compress must be "none" or "zstd"')
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
    work = work or os.path.join(os.environ.get("NETHER_WORK", "/tmp/nether-fork"), name)
    shutil.rmtree(work, ignore_errors=True); os.makedirs(work)
    kdir = os.path.join(NB, "kernels")
    if os.path.exists(kdir):
        os.symlink(kdir, os.path.join(work, "kernels"))
    open(os.path.join(work, "nether.conf"), "w").write(
        "restore=1\nrestore_from=%s\ncontrol_socket=f.sock\ndata_socket=f.data\n" % os.path.abspath(snap))
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
    shutil.rmtree(d, ignore_errors=True)
    print("selftest:", "OK" if ok else "FAILED")
    return 0 if ok else 1

# --- cli --------------------------------------------------------------------

def main(argv):
    if not argv:
        print(__doc__ if False else "usage: bake.py {bake <recipe>|fork <snap> --name N|gc [--dir D] [--orphans]|selftest}")
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
        return do_gc(d, orphans="--orphans" in argv)
    if cmd0 == "selftest":
        return selftest()
    die("unknown command: %s" % cmd0)

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
