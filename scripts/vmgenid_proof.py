#!/usr/bin/env python3
# vmgenid fork-entropy proof (the kernel-native reseed, live on HVF).
#
# Sibling forks of one base restore IDENTICAL crng state and would emit identical
# getrandom() streams. The fix: the base boots with a `microsoft,vmgenid` DT node whose
# STOCK guest driver watches a 16-byte GUID in a reserved RAM page and registers an edge
# IRQ (INTID 40). On restore nether writes a FRESH host-random GUID into the fork's COW
# copy and pulses the SPI; the guest driver calls add_vmfork_randomness() -> immediate
# crng reseed. Distinct GUIDs per fork -> divergent streams from the first post-wake draw.
#
# Proves: (1) VULN - with fork_reseed=0 (no GUID change / no IRQ) two siblings emit the
#             IDENTICAL first /dev/urandom read;
#         (2) FIX  - with the default (vmgenid on) two siblings DIFFER on the first read;
#         (3) the guest's vmgenid IRQ COUNT actually incremented on wake (the SPI landed);
#         (4) NO agent __reseed__ traffic is involved - the fork log shows the vmgenid path.
import os, socket, subprocess, sys, time, shutil

NB = os.environ.get("NETHER_ROOT") or os.path.expanduser("~/nether")
BIN = NB + "/zig-out/bin/nether"
WORK = os.environ.get("NETHER_WORK", "/tmp/nvmp")
RS = 0x1e

def uc(p, to=30):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(to); s.connect(p); return s

def un(b):
    o = bytearray(); e = False
    for x in b:
        if e: o.append(x ^ 0x40); e = False
        elif x == 0x1f: e = True
        else: o.append(x)
    return bytes(o)

def framed(s, to=30):
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

def launch(cwd, log):
    return subprocess.Popen([BIN], cwd=cwd, stdin=subprocess.DEVNULL,
                            stdout=open(os.path.join(cwd, log), "w"), stderr=subprocess.STDOUT)

def wait_sock(p, to=40):
    t0 = time.time()
    while not os.path.exists(p):
        if time.time() - t0 > to: return False
        time.sleep(0.05)
    return True

def ready(s):
    for _ in range(120):
        if "ready" in cmd(s, "echo ready", 5): return True
        time.sleep(0.5)
    return False

# First-post-wake reads: the crng draw (16 bytes) and the vmgenid IRQ count.
RAND = "head -c16 /dev/urandom | od -An -tx1 | tr -d ' \\n'"
IRQC = "awk '/vmgenid/{print $2}' /proc/interrupts"

def fork_read(base_snap, esdir, tag, reseed):
    """Restore a fork; return (first_urandom_hex, vmgenid_irq_count, logtext)."""
    d = os.path.join(WORK, tag); os.makedirs(d)
    conf = "restore=1\nrestore_from=%s\ncontrol_socket=v.sock\n" % base_snap
    if not reseed: conf += "fork_reseed=0\n"
    open(os.path.join(d, "nether.conf"), "w").write(conf)
    p = launch(d, "run.log")
    vsk = os.path.join(d, "v.sock")
    if not wait_sock(vsk, 30): return None, None, "", p
    vs = uc(vsk)
    r = cmd(vs, RAND, 10).strip()
    irq = cmd(vs, IRQC, 5).strip()
    try: cmd(vs, "__shutdown__", 5)
    except Exception: pass
    log = open(os.path.join(d, "run.log")).read()
    return r, irq, log, p

def main():
    if not os.path.exists(BIN): print("FAIL: build %s first" % BIN); return 1
    shutil.rmtree(WORK, ignore_errors=True); os.makedirs(WORK)
    base = os.path.join(WORK, "base"); os.makedirs(base)
    os.symlink(NB + "/kernels", os.path.join(base, "kernels"))
    open(os.path.join(base, "nether.conf"), "w").write("control_socket=c.sock\nram_mb=512\ncpus=2\n")
    procs = []; fails = []
    try:
        # Bake a base with the vmgenid DT node (any nether >= this change emits it).
        bp = launch(base, "boot.log"); procs.append(bp)
        if not wait_sock(os.path.join(base, "c.sock")): print("FAIL: base never came up"); return 1
        s = uc(os.path.join(base, "c.sock"))
        if not ready(s): print("FAIL: agent never ready"); return 1
        # Confirm the driver bound in the base (so its forks inherit a watching driver).
        bound = cmd(s, "ls /sys/bus/platform/drivers/vmgenid/ 2>/dev/null | grep '\\.vmgenid' || echo none", 5).strip()
        print("[base] vmgenid device bound to driver: %s" % bound)
        if ".vmgenid" not in bound: fails.append("vmgenid driver did not bind in the base")
        rep = cmd(s, "__snapshot__ base.snap", 90)
        if "OK" not in rep: fails.append("base bake failed: %r" % rep)
        cmd(s, "__shutdown__", 5); bp.wait(timeout=10)
        base_snap = os.path.join(base, "base.snap")
        base_irq = None  # the base's own vmgenid count is 0 (no generation change while live)

        # (1) VULNERABILITY: fork_reseed=0 -> no GUID change, no IRQ -> identical streams.
        v1, i1, l1, p1 = fork_read(base_snap, WORK, "vuln-a", reseed=False); procs.append(p1)
        v2, i2, l2, p2 = fork_read(base_snap, WORK, "vuln-b", reseed=False); procs.append(p2)
        print("[vuln] fork_reseed=0 first reads: a=%s b=%s (irq a=%s b=%s)" % (v1, v2, i1, i2))
        if v1 and v1 == v2:
            print("[vuln] -> IDENTICAL (the flaw, reproduced via the gate)")
        else:
            fails.append("expected identical streams with fork_reseed=0, got a=%r b=%r" % (v1, v2))

        # (2) FIX: default (vmgenid on) -> distinct GUIDs -> divergent first reads.
        f1, fi1, fl1, p3 = fork_read(base_snap, WORK, "fix-a", reseed=True); procs.append(p3)
        f2, fi2, fl2, p4 = fork_read(base_snap, WORK, "fix-b", reseed=True); procs.append(p4)
        print("[fix ] vmgenid on first reads:   a=%s b=%s (irq a=%s b=%s)" % (f1, f2, fi1, fi2))
        if f1 and f2 and f1 != f2:
            print("[fix ] -> DIVERGED on the first post-wake read")
        else:
            fails.append("expected divergent streams with vmgenid, got a=%r b=%r" % (f1, f2))
        # And they must differ from the vuln (shared) stream too.
        if f1 == v1 or f2 == v1:
            fails.append("a reseeded fork matched the un-reseeded stream (reseed had no effect)")

        # (3) the IRQ actually fired in the guest on wake (the SPI pulse landed).
        if fi1 == "1" and fi2 == "1":
            print("[fix ] vmgenid IRQ count = 1 in each fork (the SPI pulse reached the guest driver)")
        else:
            fails.append("vmgenid IRQ did not fire exactly once per fork (a=%s b=%s)" % (fi1, fi2))

        # (4) the mechanism is pure vmgenid - no agent reseed traffic.
        if "vmgenid generation change" in fl1 and "vmgenid generation change" in fl2:
            print("[fix ] fork logs show the vmgenid reseed path (no agent __reseed__ round-trip)")
        else:
            fails.append("fork log missing the vmgenid reseed line")
        if "via agent" in fl1 or "via agent" in fl2:
            fails.append("an agent-mediated reseed still ran (expected pure vmgenid)")
    finally:
        for p in procs:
            try: p.terminate()
            except Exception: pass
        time.sleep(0.4)
        for p in procs:
            try: p.kill()
            except Exception: pass
        shutil.rmtree(WORK, ignore_errors=True)
    print()
    if fails:
        print("RESULT: FAIL"); [print("  - " + f) for f in fails]; return 1
    print("RESULT: PASS - vmgenid reseeds a forked guest's crng natively: sibling forks emit")
    print("IDENTICAL streams with the reseed gated off and DIVERGENT streams with it on, the")
    print("guest's vmgenid IRQ fires once per wake, and no agent round-trip or re-bake is needed.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
