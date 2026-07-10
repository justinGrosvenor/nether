#!/usr/bin/env python3
# Guest wall-clock catch-up proof (PL031 RTC, live on HVF).
#
# Two things:
#   (A) A Nether guest had no RTC and booted at the 1970 epoch. With the PL031 the guest's
#       rtc-pl031 driver + rtc-hctosys set CLOCK_REALTIME to REAL host time at boot.
#   (B) Across a park, CLOCK_MONOTONIC is continuous (the vtimer's job) but CLOCK_REALTIME
#       FREEZES at the park moment - a guest parked for real minutes wakes thinking no wall
#       time passed. The RTC serves LIVE host time, so a woken guest reconciles with one
#       `hwclock -s` (the opt-in catch-up the platform runs on wake), jumping its wall clock
#       forward by the parked duration while monotonic stays continuous.
#
# Proves: (A) fresh boot wall clock is real (year >= 2026, not 1970);
#         (B) a fork's wall clock is FROZEN at park (~PARK_S behind real) before catch-up,
#             uptime is CONTINUOUS (not reset), and after `hwclock -s` the wall clock equals
#             real host time - a forward jump of ~PARK_S.
import os, socket, subprocess, sys, time, shutil

NB = os.environ.get("NETHER_ROOT") or os.path.expanduser("~/nether")
BIN = NB + "/zig-out/bin/nether"
WORK = os.environ.get("NETHER_WORK", "/tmp/nwc")
RS = 0x1e
PARK_S = 12  # real seconds the base stays "parked" (snapshot -> restore gap)

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

def meta(s, line, to=90):
    s.sendall(line.encode() + b"\n"); b = b""
    s.settimeout(to)
    while b"\n" not in b:
        c = s.recv(256)
        if not c: break
        b += c
    return b.decode(errors="replace").strip()

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

def gepoch(s):
    """Guest CLOCK_REALTIME as a unix epoch int (or None)."""
    v = cmd(s, "date -u +%s", 5).strip()
    try: return int(v)
    except ValueError: return None

def guptime(s):
    v = cmd(s, "cut -d' ' -f1 /proc/uptime", 5).strip()
    try: return float(v)
    except ValueError: return None

def main():
    if not os.path.exists(BIN): print("FAIL: build %s first" % BIN); return 1
    shutil.rmtree(WORK, ignore_errors=True); os.makedirs(WORK)
    base = os.path.join(WORK, "base"); fork = os.path.join(WORK, "fork")
    os.makedirs(base); os.makedirs(fork)
    os.symlink(NB + "/kernels", os.path.join(base, "kernels"))
    open(os.path.join(base, "nether.conf"), "w").write("control_socket=c.sock\nram_mb=512\ncpus=2\n")
    procs = []; fails = []
    try:
        bp = launch(base, "boot.log"); procs.append(bp)
        if not wait_sock(os.path.join(base, "c.sock")): print("FAIL: base never came up"); return 1
        s = uc(os.path.join(base, "c.sock"))
        if not ready(s): print("FAIL: agent never ready"); return 1

        # (A) fresh boot: wall clock is real, not 1970.
        gb = gepoch(s); hb = int(time.time())
        print("[boot] guest epoch=%s host epoch=%s (skew %ss)" % (gb, hb, None if gb is None else hb - gb))
        if gb is None or gb < 1_700_000_000:
            fails.append("guest wall clock not real at boot (epoch=%s, ~1970 means no RTC)" % gb)
        elif abs(hb - gb) > 3:
            fails.append("guest boot clock off from host by %ss" % (hb - gb))
        else:
            print("[boot] OK - guest booted at REAL wall time (rtc-pl031 + hctosys), not 1970")

        time.sleep(3)  # let the base accrue a clearly-nonzero uptime for the continuity check
        base_up = guptime(s)
        # Bake + park: snapshot, shut the base down, and let real wall time advance PARK_S.
        rep = meta(s, "__snapshot__ base.snap")
        print("[park] __snapshot__ -> %s" % rep.splitlines()[-1] if rep else "no reply")
        if "OK" not in rep: fails.append("snapshot failed: %r" % rep)
        try: cmd(s, "__shutdown__", 5)
        except Exception: pass
        bp.wait(timeout=10)
        print("[park] base parked; sleeping %ds of REAL wall time before wake..." % PARK_S)
        time.sleep(PARK_S)

        # (B) wake the fork and inspect its clocks BEFORE catch-up.
        open(os.path.join(fork, "nether.conf"), "w").write(
            "restore=1\nrestore_from=%s\ncontrol_socket=f.sock\n" % os.path.join(base, "base.snap"))
        fp = launch(fork, "fork.log"); procs.append(fp)
        if not wait_sock(os.path.join(fork, "f.sock"), 30): print("FAIL: fork never came up"); return 1
        fs = uc(os.path.join(fork, "f.sock"))
        gpre = gepoch(fs); fork_up = guptime(fs); real_now = int(time.time())
        behind = None if gpre is None else real_now - gpre
        print("[wake] pre-catchup: guest epoch=%s real=%s (guest is %ss behind); uptime base=%s fork=%s"
              % (gpre, real_now, behind, base_up, fork_up))
        # The wall clock must be FROZEN near the park moment (roughly PARK_S behind real).
        if gpre is None or behind is None or behind < PARK_S - 3:
            fails.append("fork wall clock not frozen at park (only %ss behind real; expected ~%ss)" % (behind, PARK_S))
        else:
            print("[wake] OK - fork wall clock FROZE at the park moment (%ss behind real)" % behind)
        # Monotonic must be CONTINUOUS (uptime carried over, not reset to ~0) - the T1 guarantee.
        if fork_up is None or base_up is None or fork_up < base_up - 1:
            fails.append("fork uptime reset (base=%.1f fork=%.1f); monotonic not continuous" % (base_up or -1, fork_up or -1))
        else:
            print("[wake] OK - monotonic continuous (uptime %.1fs -> %.1fs, no rewind despite %ds parked)" % (base_up, fork_up, PARK_S))

        # The catch-up: the opt-in one-liner the platform runs on wake.
        cmd(fs, "hwclock -s", 8)
        gpost = gepoch(fs); real2 = int(time.time())
        jump = None if (gpost is None or gpre is None) else gpost - gpre
        resid = None if gpost is None else real2 - gpost
        print("[sync] hwclock -s: guest epoch %s -> %s (jumped +%ss); now %ss off real"
              % (gpre, gpost, jump, resid))
        if gpost is None or resid is None or abs(resid) > 3:
            fails.append("after hwclock -s the guest wall clock is still %ss off real" % resid)
        elif jump is None or jump < PARK_S - 3:
            fails.append("catch-up jump was only %ss (expected ~%ss parked)" % (jump, PARK_S))
        else:
            print("[sync] OK - wall clock caught up to REAL time (+%ss ~= %ss parked), monotonic untouched" % (jump, PARK_S))

        try: cmd(fs, "__shutdown__", 5)
        except Exception: pass
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
    print("RESULT: PASS - the guest boots at REAL wall time (PL031 RTC, no more 1970); across a park")
    print("its wall clock freezes at the park moment while monotonic stays continuous, and one")
    print("`hwclock -s` on wake reconciles CLOCK_REALTIME to real time (a forward jump of the parked")
    print("duration). Wall-clock catch-up: an agent parked for real time can learn it slept.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
