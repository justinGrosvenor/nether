#!/usr/bin/env python3
# Black-box mutation fuzzer for the snapshot restore parser (live, on HVF).
#
# A snapshot file is operator / same-uid input (restore_from, validate_snapshot). A corrupt,
# truncated, or hostile file must fail CLOSED: nether rejects it cleanly (exit 1) or accepts
# a genuinely-valid one (exit 0) - but NEVER crashes (segfault / abort / Zig panic / OOB) and
# NEVER hangs. `validate_snapshot=<path>` runs the full header + section parser WITHOUT
# booting, so we can hammer hundreds of mutants of a REAL snapshot in seconds.
#
# Generates: single/multi random byte flips, per-header-field corruption (magic, version,
# num_cpus, ram/disk/gic sizes, ram_off, kind, cntvct, fingerprints), and truncations at
# every structural boundary. Each mutant -> `validate_snapshot`; a subset also -> real
# `restore` (asserting only nether's own memory-safety, since a benign-header mutant may boot
# a doomed guest). PASS iff zero crashes and zero hangs across all mutants.
import os, socket, subprocess, sys, time, shutil, struct, random, resource

NB = os.environ.get("NETHER_ROOT") or os.path.expanduser("~/nether")
BIN = NB + "/zig-out/bin/nether"
WORK = os.environ.get("NETHER_WORK", "/tmp/nfz")
RS = 0x1e
# Safety rails so the fuzzer can NEVER exhaust the host (an early run booting real VMs on
# corrupt input contributed to a machine freeze). Every child runs under a hard CPU-second
# cap (kernel-enforced via SIGXCPU, works on macOS - a real backstop the wall-clock timeout
# is not) and an address-space cap (best-effort; enforced on Linux, often a no-op on macOS -
# which is why the DEFAULT path boots NOTHING; see below).
CHILD_CPU_S = int(os.environ.get("NETHER_FUZZ_CPU", "15"))   # hard CPU-time cap per child
CHILD_AS_GB = int(os.environ.get("NETHER_FUZZ_AS_GB", "3"))  # address-space cap per child
# Live-boot restore subset is OPT-IN and capped: the no-boot validate_snapshot path is what
# actually stresses the parser and allocates no guest RAM, so it is the safe default. Set
# NETHER_FUZZ_LIVE=N (N>0) to also boot up to N real VMs on mutant files.
LIVE_RESTORES = min(int(os.environ.get("NETHER_FUZZ_LIVE", "0")), 24)

def _child_limits():
    """preexec in each child: cap CPU seconds (SIGXCPU) and address space. Best-effort:
    a cap the platform rejects is skipped rather than failing the spawn."""
    try:
        resource.setrlimit(resource.RLIMIT_CPU, (CHILD_CPU_S, CHILD_CPU_S + 2))
    except (ValueError, OSError):
        pass
    try:
        n = CHILD_AS_GB * 1024 * 1024 * 1024
        resource.setrlimit(resource.RLIMIT_AS, (n, n))
    except (ValueError, OSError):
        pass
random.seed(0xFACADE)  # reproducible

def un(b):
    o = bytearray(); e = False
    for x in b:
        if e: o.append(x ^ 0x40); e = False
        elif x == 0x1f: e = True
        else: o.append(x)
    return bytes(o)

def framed(s, to=90):
    s.settimeout(to); b = b""
    while RS not in b:
        c = s.recv(4096)
        if not c: return un(b), None
        b += c
    rs = b.index(RS)
    while b"\n" not in b[rs + 1:]: b += s.recv(64)
    return un(b[:rs]), int(b[rs + 1:b.index(b"\n", rs + 1)])

def cmd(s, line, to=30):
    s.sendall(line.encode() + b"\n"); b, e = framed(s, to); return b.decode(errors="replace")

def meta(s, line, to=90):
    s.sendall(line.encode() + b"\n"); s.settimeout(to); b = b""
    while b"\n" not in b:
        c = s.recv(256)
        if not c: break
        b += c
    return b.decode(errors="replace").strip()

def bake_base():
    base = os.path.join(WORK, "base"); os.makedirs(base)
    os.symlink(NB + "/kernels", os.path.join(base, "kernels"))
    open(os.path.join(base, "nether.conf"), "w").write("control_socket=c.sock\nram_mb=512\ncpus=2\n")
    p = subprocess.Popen([BIN], cwd=base, stdin=subprocess.DEVNULL,
                         stdout=open(base + "/boot.log", "w"), stderr=subprocess.STDOUT)
    csk = os.path.join(base, "c.sock"); t0 = time.time()
    while not os.path.exists(csk) and time.time() - t0 < 40: time.sleep(0.1)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(20); s.connect(csk)
    for _ in range(120):
        if "ready" in cmd(s, "echo ready", 5): break
        time.sleep(0.5)
    rep = meta(s, "__snapshot__ base.snap")
    try: cmd(s, "__shutdown__", 5)
    except Exception: pass
    p.wait(timeout=10)
    snap = os.path.join(base, "base.snap")
    return snap if ("OK" in rep and os.path.exists(snap)) else None

# Header field layout (offset, width) - the parser's trust surface.
FIELDS = [(0,4),(4,4),(8,4),(12,4),(24,8),(32,8),(40,8),(48,8),(56,4),(60,4),
          (64,4),(68,4),(72,4),(76,4),(80,4),(88,8)]
EXTREMES = [0, 1, 2**8-1, 2**16, 2**31, 2**32-1, 2**63, 2**64-1]

def mutants(good):
    n = len(good); out = []
    # 1. random single + multi-byte flips
    for _ in range(120):
        b = bytearray(good); pos = random.randrange(n); b[pos] = random.randrange(256); out.append(("flip1@%d" % pos, bytes(b)))
    for _ in range(80):
        b = bytearray(good); pos = random.randrange(max(1, n - 32)); ln = random.randrange(1, 32)
        for k in range(ln):
            if pos + k < n: b[pos + k] = random.randrange(256)
        out.append(("flipN@%d+%d" % (pos, ln), bytes(b)))
    # 2. per-header-field extremes (the parser's trust surface)
    for (off, w) in FIELDS:
        for v in EXTREMES:
            b = bytearray(good)
            b[off:off+w] = (v & ((1 << (8*w)) - 1)).to_bytes(w, "little")
            out.append(("field@%d=%d" % (off, v & ((1<<(8*w))-1)), bytes(b)))
    # 3. truncations at structural boundaries
    for k in sorted(set([0, 1, 63, 64, 127, 128, 129, 256, 4096, 16384, 16384+128,
                         n//4, n//2, n-16384, n-4096, n-1])):
        if 0 <= k <= n: out.append(("trunc@%d" % k, bytes(good[:k])))
    # 4. oversize/garbage tail
    for _ in range(10):
        out.append(("tail+garbage", bytes(good) + bytes(random.randrange(256) for _ in range(random.randrange(1, 4096)))))
    return out

def classify(cwd, conf, timeout=8):
    """Run nether with `conf` in cwd under the child resource caps; return one of
    accepted/rejected/CRASH/HANG. `timeout` is the wall-clock backstop (the kernel CPU cap
    is the harder one). validate_snapshot is a no-boot parser that exits in <1s, so the
    default is tight; the opt-in live-restore path passes a larger value."""
    open(os.path.join(cwd, "nether.conf"), "w").write(conf)
    try:
        r = subprocess.run([BIN], cwd=cwd, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout, preexec_fn=_child_limits)
    except subprocess.TimeoutExpired:
        return "HANG", ""
    out = r.stdout.decode(errors="replace")
    low = out.lower()
    if r.returncode < 0 or r.returncode in (134, 133, 139, 132) or \
       any(m in low for m in ("panic", "segmentation", "reached unreachable", "index out of bounds",
                              "integer overflow", "sanitizer", "cast truncated")):
        return "CRASH", out
    return ("accepted" if r.returncode == 0 else "rejected"), out

def main():
    if not os.path.exists(BIN): print("FAIL: build %s first" % BIN); return 1
    shutil.rmtree(WORK, ignore_errors=True); os.makedirs(WORK)
    fails = []
    try:
        snap = bake_base()
        if not snap: print("FAIL: could not bake a base snapshot"); return 1
        good = open(snap, "rb").read()
        print("[bake] base snapshot: %d bytes" % len(good))
        # sanity: the pristine file validates OK
        vdir = os.path.join(WORK, "v"); os.makedirs(vdir)
        os.symlink(NB + "/kernels", os.path.join(vdir, "kernels"))
        cls, _ = classify(vdir, "validate_snapshot=%s\n" % snap)
        print("[bake] pristine file validate -> %s" % cls)
        if cls != "accepted": fails.append("pristine snapshot did not validate (%s)" % cls)

        muts = mutants(good)
        print("[fuzz] %d mutants -> validate_snapshot (no boot)..." % len(muts))
        tally = {"accepted": 0, "rejected": 0, "CRASH": 0, "HANG": 0}
        mpath = os.path.join(WORK, "m.snap")
        crashes = []
        for i, (name, data) in enumerate(muts):
            open(mpath, "wb").write(data)
            cls, out = classify(vdir, "validate_snapshot=%s\n" % mpath)
            tally[cls] += 1
            if cls in ("CRASH", "HANG"):
                crashes.append((name, cls, out[-300:]))
            if (i + 1) % 60 == 0:
                print("  ... %d/%d  (rej=%d acc=%d CRASH=%d HANG=%d)"
                      % (i + 1, len(muts), tally["rejected"], tally["accepted"], tally["CRASH"], tally["HANG"]))
        print("[fuzz] validate: rejected=%d accepted=%d CRASH=%d HANG=%d"
              % (tally["rejected"], tally["accepted"], tally["CRASH"], tally["HANG"]))
        if tally["CRASH"] or tally["HANG"]:
            fails.append("validate parser: %d crashes, %d hangs" % (tally["CRASH"], tally["HANG"]))
            for nm, c, tail in crashes[:8]: print("   %s [%s]: ...%s" % (nm, c, tail.replace("\n", " ")))

        # OPT-IN: a subset through the REAL restore path (boots a VM per mutant), asserting
        # nether's own memory-safety. Off by default because it boots real VMs - the no-boot
        # validate pass above already exercises the full header+section parser. Each child
        # runs under the CPU + address-space caps; a benign-header mutant may boot a doomed
        # guest (a HANG there is the guest, killed by timeout - fine; only a nether CRASH fails).
        if LIVE_RESTORES > 0:
            rdir = os.path.join(WORK, "r"); os.makedirs(rdir)
            os.symlink(NB + "/kernels", os.path.join(rdir, "kernels"))
            subset = random.sample(muts, min(LIVE_RESTORES, len(muts)))
            rcrash = 0
            print("[fuzz] %d mutants -> real restore (opt-in, memory-safety only)..." % len(subset))
            for name, data in subset:
                open(mpath, "wb").write(data)
                cls, out = classify(rdir, "restore=1\nrestore_from=%s\ncontrol_socket=r.sock\nram_mb=512\n" % mpath, timeout=12)
                if cls == "CRASH":
                    rcrash += 1; print("   restore CRASH on %s: ...%s" % (name, out[-200:].replace("\n", " ")))
            print("[fuzz] restore: %d/%d nether-side crashes" % (rcrash, len(subset)))
            if rcrash: fails.append("restore path: %d nether crashes on corrupt files" % rcrash)
        else:
            print("[fuzz] live-restore subset SKIPPED (set NETHER_FUZZ_LIVE=N to boot up to N real VMs)")
    finally:
        shutil.rmtree(WORK, ignore_errors=True)
    print()
    if fails:
        print("RESULT: FAIL"); [print("  - " + f) for f in fails]; return 1
    live = "+ %d live restores" % LIVE_RESTORES if LIVE_RESTORES > 0 else "no-boot only"
    print("RESULT: PASS - the snapshot restore parser fails CLOSED on every mutant (%s):" % live)
    print("corrupt/truncated/hostile files are cleanly rejected (or a valid one accepted), with")
    print("zero crashes and zero hangs across byte-flip, header-field, and truncation fuzzing.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
