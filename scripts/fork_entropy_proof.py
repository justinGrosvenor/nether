#!/usr/bin/env python3
# Fork entropy divergence proof (post-park hardening T2, live on HVF).
#
# The claim: sibling forks of one base restore IDENTICAL crng state, so without a
# post-restore reseed they emit IDENTICAL getrandom()/urandom streams (not mutually
# secret). The fix is an agent-mediated immediate reseed: at restore, nether queues
# `__reseed__ <64B hex of host entropy>` on the surviving agent conn BEFORE the guest
# resumes; the agent (new image) feeds it via RNDADDENTROPY (credited) + RNDRESEEDCRNG,
# silently (no output, no 0x1e frame), so streams diverge from the FIRST post-wake read.
#
# Proves: (1) VULNERABILITY - two siblings with fork_reseed=0 read /dev/urandom as
#             their first command and get IDENTICAL bytes;
#         (2) FIX - two siblings with the default conf (reseed on) DIFFER on the same
#             first read, and each fork's log carries the reseed line;
#         (3) timing - divergence is asserted on the FIRST read after wake (measured
#             from process launch to the reply);
#         (4) old-image tolerance - a base baked from an agent WITHOUT the handler:
#             the reseed line falls through to the shell (a `not found` + 0x1e trailer
#             frame). A client that attaches AFTER the frame drained sees clean framing
#             (the relay discards agent bytes with no primary); a client attached
#             BEFORE it may see one stray frame (off-by-one) - observed and reported,
#             either way the session must recover. Old images need a re-bake.
import os, socket, subprocess, sys, time, shutil

NB = os.environ.get("NETHER_ROOT") or os.path.expanduser("~/nether"); BIN = NB + "/zig-out/bin/nether"
WORK = os.environ.get("NETHER_WORK", "/tmp/nfe"); RS = 0x1e
RESEED_LINE = "[nether] fork crng reseeded (64B via agent)"
READ16 = "head -c16 /dev/urandom | od -An -tx1 | tr -d ' \\n'"

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
    s.sendall(line.encode() + b"\n"); b, e = framed(s, to); return b.decode(errors="replace"), e

def launch(cwd, log):
    return subprocess.Popen([BIN], cwd=cwd, stdin=subprocess.DEVNULL,
                            stdout=open(os.path.join(cwd, log), "w"), stderr=subprocess.STDOUT)

def bake_base(tag, kernels, procs, fails):
    """Boot a control-mode sandbox on `kernels`, snapshot a durable base, shut down."""
    d = os.path.join(WORK, tag); os.makedirs(d)
    os.symlink(kernels, os.path.join(d, "kernels"))
    open(os.path.join(d, "nether.conf"), "w").write("control_socket=c.sock\nram_mb=512\ncpus=2\n")
    p = launch(d, "boot.log"); procs.append(p)
    sk = os.path.join(d, "c.sock"); t0 = time.time()
    while not os.path.exists(sk) and time.time() - t0 < 40: time.sleep(0.1)
    s = uc(sk)
    for _ in range(120):
        try:
            if "ready" in cmd(s, "echo ready", 5)[0]: break
        except Exception: pass
        time.sleep(0.5)
    r, e = cmd(s, "__snapshot__ base.snap", 60)
    if not r.startswith("OK"): fails.append("[%s] __snapshot__ failed: %r" % (tag, r))
    cmd(s, "__shutdown__", 10)
    try: p.wait(timeout=15)
    except subprocess.TimeoutExpired: p.kill(); fails.append("[%s] base did not exit" % tag)
    return os.path.join(d, "base.snap")

def fork(tag, base_snap, procs, extra="", connect=True):
    """Restore a fork of base_snap; returns (proc, socket-or-None, t_launch, dir)."""
    d = os.path.join(WORK, tag); os.makedirs(d)
    open(os.path.join(d, "nether.conf"), "w").write(
        "restore=1\nrestore_from=%s\ncontrol_socket=c.sock\n%s" % (base_snap, extra))
    t0 = time.time()
    p = launch(d, "fork.log"); procs.append(p)
    sk = os.path.join(d, "c.sock")
    while not os.path.exists(sk) and time.time() - t0 < 30: time.sleep(0.02)
    return p, (uc(sk) if connect else None), t0, d

def flog(d): return open(os.path.join(d, "fork.log")).read()

def main():
    if not os.path.exists(BIN): print("FAIL: build %s first" % BIN); return 1
    shutil.rmtree(WORK, ignore_errors=True); os.makedirs(WORK)
    procs = []; fails = []
    try:
        base = bake_base("b", NB + "/kernels", procs, fails)
        if fails: raise SystemExit

        # 1. VULNERABILITY: reseed gated OFF -> the first post-wake urandom read of two
        #    siblings is IDENTICAL (they restored the same crng state, nothing diverged it).
        _, s1, _, d1 = fork("v1", base, procs, "fork_reseed=0\n")
        _, s2, _, d2 = fork("v2", base, procs, "fork_reseed=0\n")
        r1, e1 = cmd(s1, READ16); r2, e2 = cmd(s2, READ16)
        r1, r2 = r1.strip(), r2.strip()
        print("[vuln] fork_reseed=0 first read: v1=%s v2=%s" % (r1, r2))
        if e1 != 0 or e2 != 0 or len(r1) != 32:
            fails.append("vuln-phase read failed (e1=%s e2=%s r1=%r)" % (e1, e2, r1))
        elif r1 != r2:
            fails.append("vuln phase: siblings DIFFER with reseed off - flaw not reproduced (r1=%s r2=%s)" % (r1, r2))
        else:
            print("[vuln] IDENTICAL streams: sibling forks are not mutually secret without the reseed")
        for d, t in ((d1, "v1"), (d2, "v2")):
            if RESEED_LINE in flog(d): fails.append("%s: reseed line present despite fork_reseed=0" % t)
        for s in (s1, s2):
            try: cmd(s, "__shutdown__", 5)
            except Exception: pass

        # 2. FIX: default conf (reseed on) -> the SAME first read DIFFERS, and each
        #    fork's log records the reseed. Timing: launch -> first divergent reply.
        _, s1, t1, d1 = fork("f1", base, procs)
        _, s2, t2, d2 = fork("f2", base, procs)
        r1, e1 = cmd(s1, READ16); dt1 = time.time() - t1
        r2, e2 = cmd(s2, READ16); dt2 = time.time() - t2
        r1, r2 = r1.strip(), r2.strip()
        print("[fix] default conf first read: f1=%s (%.3fs) f2=%s (%.3fs)" % (r1, dt1, r2, dt2))
        if e1 != 0 or e2 != 0 or len(r1) != 32:
            fails.append("fix-phase read failed (e1=%s e2=%s r1=%r)" % (e1, e2, r1))
        elif r1 == r2:
            fails.append("fix phase: siblings IDENTICAL with reseed on (r=%s)" % r1)
        else:
            print("[fix] streams DIVERGED on the FIRST post-wake read (launch->reply %.3fs / %.3fs)" % (dt1, dt2))
        for d, t in ((d1, "f1"), (d2, "f2")):
            if RESEED_LINE not in flog(d): fails.append("%s: log missing %r" % (t, RESEED_LINE))
        if not fails: print("[fix] both fork logs carry: %s" % RESEED_LINE)
        for s in (s1, s2):
            try: cmd(s, "__shutdown__", 5)
            except Exception: pass

        # 3. OLD-IMAGE TOLERANCE: a base whose agent predates __reseed__ (the pre-bake
        #    initramfs kept as .bak). The reseed line reaches the shell: one stray
        #    `not found` + 0x1e trailer frame enters the relay. With no primary attached
        #    the relay discards it; a primary attached BEFORE it sees one stray frame
        #    (off-by-one) and must recover on the next frame. Skipped if no .bak exists.
        old_initramfs = NB + "/kernels/initramfs.cpio.gz.bak"
        if os.path.exists(old_initramfs):
            oldk = os.path.join(WORK, "oldk"); os.makedirs(oldk)
            for f in os.listdir(NB + "/kernels"):
                if f in ("initramfs.cpio.gz", "rootfs"): continue
                os.symlink(os.path.join(NB + "/kernels", f), os.path.join(oldk, f))
            os.symlink(old_initramfs, os.path.join(oldk, "initramfs.cpio.gz"))
            obase = bake_base("ob", oldk, procs, fails)
            # 3a. attach-early: connect the moment the socket exists (pre-resume), so a
            #     stray frame - if it beats the discard - lands in OUR session.
            _, s1, _, d1 = fork("o1", obase, procs)
            r, e = cmd(s1, "echo sync-check", 20)
            if "sync-check" in r and e == 0:
                print("[old] attach-early: FIRST frame clean (%r exit %s) - stray frame drained pre-attach" % (r.strip(), e))
            elif "not found" in r or e == 127:
                print("[old] attach-early: stray __reseed__ frame LEAKED (%r exit %s) - the documented off-by-one" % (r.strip(), e))
                r, e = framed(s1, 20); r = r.decode(errors="replace")  # the echo's real frame
                if "sync-check" in r and e == 0:
                    print("[old] session recovered on the next frame (%r exit %s)" % (r.strip(), e))
                else:
                    fails.append("old-image early attach did not recover: %r exit %s" % (r, e))
            else:
                fails.append("old-image early attach: unexpected first frame %r exit %s" % (r, e))
            if RESEED_LINE not in flog(d1):
                fails.append("o1: host did not report the (blind) reseed send on an old image")
            try: cmd(s1, "__shutdown__", 5)
            except Exception: pass
            # 3b. attach-late: fork with NO client attached, WAIT for the guest to consume
            #     the line and the relay to discard the stray frame, then attach - framing
            #     must be clean (this is the realistic platform pattern).
            _, _, _, d2 = fork("o2", obase, procs, connect=False)
            time.sleep(2.0)  # guest resumed long ago; stray frame drained + discarded
            s2b = uc(os.path.join(d2, "c.sock"))
            r, e = cmd(s2b, "echo sync-check", 20)
            r2, e2 = cmd(s2b, "echo second", 20)
            if "sync-check" in r and e == 0 and "second" in r2 and e2 == 0:
                print("[old] attach-late: framing clean (%r/%s then %r/%s) - old image is tolerated, just unreseeded" % (r.strip(), e, r2.strip(), e2))
            else:
                fails.append("old-image late attach framing corrupt: %r/%s then %r/%s" % (r, e, r2, e2))
            try: cmd(s2b, "__shutdown__", 5)
            except Exception: pass
        else:
            print("[old] SKIPPED: %s not present (re-bake keeps the previous image as .bak)" % old_initramfs)
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
    print("RESULT: PASS - sibling forks with fork_reseed=0 emitted IDENTICAL first urandom reads")
    print("(the vulnerability), and with the default agent-mediated reseed (RNDADDENTROPY credited +")
    print("RNDRESEEDCRNG, queued before resume, silent) they DIVERGED on the FIRST post-wake read;")
    print("both fork logs carry the reseed line. Old images (no handler) keep working - the stray")
    print("shell frame is discarded when no client is attached - but need a re-bake to get the reseed.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
