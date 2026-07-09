#!/usr/bin/env python3
# Virtual-timer continuity across park/wake (T1), live on HVF.
#
# The claim: the snapshot is the guest's LAST LIVE MOMENT. A woken fork's virtual
# counter resumes exactly at its captured value, so (1) the guest monotonic clock
# (/proc/uptime) CONTINUES from the pre-park value - it neither rewinds to ~0 nor
# jumps forward by the parked wall time - and (2) a guest timer armed pre-park keeps
# its REMAINING duration: a `sleep 3` parked 1s in fires ~2s after wake, not
# instantly (the pre-fix behavior: the counter jumped past the armed comparator) and
# not ~12s late. A parked guest does not observe the parked wall time.
#
# Mechanics under test: capture publishes cpu0's CNTVCT (host counter - vtimer
# offset) into the snapshot header (hdr[88..96]); the restore computes ONE offset =
# host-counter-now - captured-CNTVCT and every vCPU applies it from its owning
# thread via hv_vcpu_set_vtimer_offset (CNTVOFF_EL2 through the sys-reg API is
# HV_UNSUPPORTED - the old silent no-op).
#
# Proves: (1) /proc/uptime continuity across park/wake (gen 1);
#         (2) an armed timer's remaining duration is preserved across ~10s parked;
#         (3) a re-parked fork's clock is STILL continuous (generation 2).
import os, socket, subprocess, sys, time, threading, shutil

NB = os.environ.get("NETHER_ROOT") or os.path.expanduser("~/nether"); BIN = NB + "/zig-out/bin/nether"
WORK = os.environ.get("NETHER_WORK", "/tmp/npt")  # AF_UNIX paths cap ~104B on macOS: keep it short
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

def framed(s, to=60):
    s.settimeout(to); b = b""
    while RS not in b:
        c = s.recv(4096)
        if not c: return un(b), None
        b += c
    rs = b.index(RS)
    while b"\n" not in b[rs + 1:]: b += s.recv(64)
    return un(b[:rs]), int(b[rs + 1:b.index(b"\n", rs + 1)])

def cmd(s, line, to=60):
    s.sendall(line.encode() + b"\n"); b, e = framed(s, to); return b.decode(errors="replace")

def uptime(s):
    out = cmd(s, "cat /proc/uptime", 8).strip().split()
    return float(out[0]) if out else -1.0

def launch(cwd, log):
    return subprocess.Popen([BIN], cwd=cwd, stdin=subprocess.DEVNULL,
                            stdout=open(os.path.join(cwd, log), "w"), stderr=subprocess.STDOUT)

class EgressHolder:
    """Minimal platform stand-in: owns the egress_socket listener so the VM runs the
    real egress-plane shape (same conf as park_await). This proof drives no egress
    traffic - any dial is just accepted and held."""
    def __init__(self, path):
        if os.path.exists(path): os.unlink(path)
        self.ls = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.ls.bind(path); self.ls.listen(8)
        self.held = []
        threading.Thread(target=self._loop, daemon=True).start()
    def _loop(self):
        while True:
            try: c, _ = self.ls.accept()
            except Exception: return
            self.held.append(c)

def wake(dirpath, snap_path, sockname, esock):
    os.makedirs(dirpath, exist_ok=True)
    open(os.path.join(dirpath, "nether.conf"), "w").write(
        "restore=1\nrestore_from=%s\ncontrol_socket=%s\negress_socket=%s\n" % (snap_path, sockname, esock))
    t0 = time.time()
    p = launch(dirpath, "fork.log")
    sk = os.path.join(dirpath, sockname)
    while not os.path.exists(sk) and time.time() - t0 < 30: time.sleep(0.02)
    return p, uc(sk), t0

def main():
    if not os.path.exists(BIN): print("FAIL: build %s first" % BIN); return 1
    shutil.rmtree(WORK, ignore_errors=True)
    base = os.path.join(WORK, "b")
    os.makedirs(base)
    os.symlink(NB + "/kernels", os.path.join(base, "kernels"))
    esock = os.path.join(WORK, "e.sock")
    open(os.path.join(base, "nether.conf"), "w").write(
        "control_socket=c.sock\negress_socket=%s\negress_port=9090\nram_mb=512\ncpus=2\n" % esock)
    _holder = EgressHolder(esock)
    procs = []; fails = []
    try:
        # 1. Boot; wait for the agent; age the guest to ~15s uptime.
        bp = launch(base, "boot.log"); procs.append(bp)
        csk = os.path.join(base, "c.sock")
        t0 = time.time()
        while not os.path.exists(csk) and time.time() - t0 < 40: time.sleep(0.1)
        s = uc(csk)
        for _ in range(120):
            if "ready" in cmd(s, "echo ready", 5): break
            time.sleep(0.5)
        up = uptime(s)
        while up < 15.0 and time.time() - t0 < 60:
            time.sleep(0.5); up = uptime(s)
        print("[base] guest aged to uptime %.2fs" % up)
        if up < 15.0: fails.append("guest never reached 15s uptime (%.2f)" % up)

        # 2. Arm the pre-park timer, park ~1s in (so ~2s of the sleep remains).
        cmd(s, "rm -f /tmp/t3; (sleep 3 && touch /tmp/t3) >/dev/null 2>&1 &", 10)
        t_armed = time.time()
        time.sleep(1.0)
        up_pre = uptime(s)
        t_park_sent = time.time()
        rep = cmd(s, "__park__ park.snap", 90)
        print("[park] pre-park uptime %.2fs; timer armed %.2fs before the park; reply: %s"
              % (up_pre, t_park_sent - t_armed, rep.strip()[:60]))
        if not rep.startswith("OK parked"): fails.append("__park__ failed: %r" % rep)
        try:
            rc = bp.wait(timeout=10)
            if rc != 0: fails.append("park exit code %s != 0" % rc)
        except subprocess.TimeoutExpired:
            fails.append("nether did not exit after __park__"); bp.kill()
        remaining = 3.0 - (t_park_sent - t_armed)  # sleep time left at the capture (host-clock estimate)

        # 3. Stay parked ~10s of wall time (the guest must not observe this).
        parked_s = 10.0
        time.sleep(parked_s)

        # 4. Wake. FIRST response: uptime must CONTINUE from up_pre (not ~0.7 - the old
        #    rewind - and not up_pre+~10 - the pre-fix forward jump by the parked wall
        #    time), and /tmp/t3 must NOT exist yet (the timer did not fire while parked
        #    or instantly at wake).
        fp, fs, t_w0 = wake(os.path.join(WORK, "f1"), os.path.join(base, "park.snap"), "f.sock", esock)
        procs.append(fp)
        first = cmd(fs, "cat /proc/uptime; test -f /tmp/t3 && echo T3-PRESENT || echo T3-ABSENT", 15)
        t_first = time.time()
        up_wake = float(first.split()[0]); t3_at_wake = "T3-PRESENT" in first
        print("[wake] first response %.2fs after launch: uptime %.2fs (pre-park %.2fs, parked %.1fs wall); t3 %s"
              % (t_first - t_w0, up_wake, up_pre, parked_s, "PRESENT" if t3_at_wake else "absent"))
        if up_wake < up_pre - 0.3:
            fails.append("uptime REWOUND across the park (%.2f -> %.2f)" % (up_pre, up_wake))
        if up_wake > up_pre + 4.0:
            fails.append("uptime jumped by the parked wall time (%.2f -> %.2f; continuity broken)" % (up_pre, up_wake))
        if t3_at_wake:
            fails.append("armed timer fired during the park or instantly at wake (t3 already present)")

        # 5. The timer must fire with its REMAINING duration (~2s), not instantly, not
        #    ~12s late. Generous +-1s-ish tolerances around the host-clock estimate.
        t3_seen = None
        while time.time() - t_first < 15.0:
            if "T3-PRESENT" in cmd(fs, "test -f /tmp/t3 && echo T3-PRESENT || echo T3-ABSENT", 8):
                t3_seen = time.time(); break
            time.sleep(0.1)
        if t3_seen is None:
            fails.append("armed timer never fired after wake")
        else:
            delta = t3_seen - t_first
            print("[timer] t3 appeared %.2fs after the first wake response (remaining at park ~%.2fs)" % (delta, remaining))
            if delta < max(0.3, remaining - 1.5):
                fails.append("timer fired too early after wake (%.2fs; remaining was ~%.2fs)" % (delta, remaining))
            if delta > remaining + 1.5:
                fails.append("timer fired late after wake (%.2fs; remaining was ~%.2fs - the base-age/park-age lag)" % (delta, remaining))
        flog = open(os.path.join(WORK, "f1", "fork.log")).read()
        if "vtimer continuity" not in flog:
            fails.append("fork log missing the 'vtimer continuity' restore line")

        # 6. GENERATION 2: re-park the woken fork; uptime must still be continuous.
        up2_pre = uptime(fs)
        rep2 = cmd(fs, "__park__ park2.snap", 90)
        print("[gen2] re-park at uptime %.2fs; reply: %s" % (up2_pre, rep2.strip()[:60]))
        if not rep2.startswith("OK parked"): fails.append("fork __park__ failed: %r" % rep2)
        try:
            rcf = fp.wait(timeout=10)
            if rcf != 0: fails.append("fork park exit code %s != 0" % rcf)
        except subprocess.TimeoutExpired:
            fails.append("fork did not exit after __park__"); fp.kill()
        time.sleep(4.0)  # parked again
        f2p, f2s, _ = wake(os.path.join(WORK, "f2"), os.path.join(WORK, "f1", "park2.snap"), "f2.sock", esock)
        procs.append(f2p)
        second = cmd(f2s, "cat /proc/uptime; test -f /tmp/t3 && echo T3-PRESENT || echo T3-ABSENT", 15)
        up_wake2 = float(second.split()[0])
        print("[gen2] woken uptime %.2fs (pre-park %.2fs, parked 4s wall); t3 %s"
              % (up_wake2, up2_pre, "carried" if "T3-PRESENT" in second else "MISSING"))
        if up_wake2 < up2_pre - 0.3:
            fails.append("gen-2 uptime rewound (%.2f -> %.2f)" % (up2_pre, up_wake2))
        if up_wake2 > up2_pre + 4.0:
            fails.append("gen-2 uptime jumped by the parked wall time (%.2f -> %.2f)" % (up2_pre, up_wake2))
        if "T3-PRESENT" not in second:
            fails.append("gen-1 state (/tmp/t3) lost across the re-park")

        try: cmd(f2s, "__shutdown__", 5)
        except Exception: pass
    except SystemExit: pass
    finally:
        for p in procs:
            try: p.terminate()
            except Exception: pass
        time.sleep(0.4)
        for p in procs:
            try: p.kill()
            except Exception: pass
    print()
    if fails:
        print("RESULT: FAIL"); [print("  - " + f) for f in fails]; return 1
    print("RESULT: PASS - the guest's virtual counter resumes exactly at its captured value:")
    print("/proc/uptime CONTINUED across a ~10s park (no rewind, no forward jump by the parked")
    print("wall time), a pre-park `sleep 3` fired with its REMAINING ~2s after wake (not")
    print("instantly, not ~12s late), and a re-parked fork (generation 2) stayed continuous.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
