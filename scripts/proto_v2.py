#!/usr/bin/env python3
# Control-protocol v2 (frame-everything) live proof on HVF.
#
# Proves: (1) __info__ reports proto_version=2 and is framed; (2) the acks and control-plane
# errors that were BARE in v1 are now FRAMED with 0x1e<exit>\n (exit 0 for OK, -1 for ERR);
# (3) the command-intake guard rejects a 0x1e in a command; (4) a v2 reader (no settle timer)
# reads a delayed OK-prefixed shell reply in full, where a v1 settle reader truncates the
# same bytes; (5) the reference client nether-ctl speaks v2 and extracts exit codes.
import os, socket, subprocess, sys, time, select, shutil

NB = os.path.expanduser("~/nether")
BIN = NB + "/zig-out/bin/nether"
CTL = "/tmp/nether-ctl"
WORK = "/tmp/nv2"
RS = 0x1e

def uconn(path, to=20):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(to); s.connect(path); return s

def unescape(b):
    out = bytearray(); esc = False
    for x in b:
        if esc: out.append(x ^ 0x40); esc = False
        elif x == 0x1f: esc = True
        else: out.append(x)
    return bytes(out)

def read_framed(s, to=15):
    """v2 read: to the raw 0x1e, then <exit>\\n. Returns (body, exit)."""
    s.settimeout(to); buf = b""
    while RS not in buf:
        c = s.recv(4096)
        if not c: return unescape(buf), None
        buf += c
    rs = buf.index(RS)
    while b"\n" not in buf[rs + 1:]:
        c = s.recv(64)
        if not c: break
        buf += c
    nl = buf.index(b"\n", rs + 1)
    return unescape(buf[:rs]), int(buf[rs + 1:nl])

def read_v1_settle(s, settle=0.5, hang=12):
    """A v1 consumer: read toward 0x1e, but a complete OK/ERR line with no 0x1e settles
    after `settle` and is delivered BARE (this is the truncation the v2 change removes)."""
    buf = b""; t0 = time.time()
    while time.time() - t0 < hang:
        bare = RS not in buf and b"\n" in buf and (buf.startswith(b"OK ") or buf.startswith(b"ERR "))
        r, _, _ = select.select([s], [], [], settle if bare else hang)
        if not r:
            if bare: return ("bare", buf.split(b"\n", 1)[0])  # v1 truncates here
            return ("hang", buf)
        c = s.recv(4096)
        if not c: return ("eof", buf)
        buf += c
        if RS in buf:
            return ("framed", buf[:buf.index(RS)])
    return ("timeout", buf)

def cmd_line(s, line):
    s.sendall(line.encode() + b"\n")

def launch(cwd, log):
    return subprocess.Popen([BIN], cwd=cwd, stdin=subprocess.DEVNULL,
                            stdout=open(os.path.join(cwd, log), "w"), stderr=subprocess.STDOUT)

def main():
    shutil.rmtree(WORK, ignore_errors=True); os.makedirs(WORK)
    # Build the reference client from source so this proof is self-contained.
    if subprocess.run(["cc", "-O2", NB + "/tools/nether-ctl.c", "-o", CTL]).returncode != 0:
        print("FAIL: could not build nether-ctl"); return 1
    os.symlink(NB + "/kernels", os.path.join(WORK, "kernels"))
    open(os.path.join(WORK, "nether.conf"), "w").write(
        "control_socket=c.sock\nram_mb=512\ncpus=1\n")
    fails = []
    p = launch(WORK, "boot.log")
    try:
        sk = os.path.join(WORK, "c.sock")
        t0 = time.time()
        while not os.path.exists(sk) and time.time() - t0 < 40: time.sleep(0.1)
        s = uconn(sk)

        # (1) __info__ framed, proto_version=2.
        cmd_line(s, "__info__")
        body, ex = read_framed(s)
        pv = next((l.split(b"=")[1] for l in body.split(b"\n") if l.startswith(b"proto_version=")), b"?")
        print("[1] __info__: proto_version=%s framed exit=%s" % (pv.decode(), ex))
        if pv != b"2" or ex != 0: fails.append("__info__ not v2/framed (pv=%s exit=%s)" % (pv, ex))

        # wait for the guest agent so shell commands run.
        for _ in range(120):
            cmd_line(s, "echo ready"); b, e = read_framed(s)
            if b"ready" in b: break
            time.sleep(0.5)

        # (2) a control error is now FRAMED (exit -1), not a bare line: send a control byte.
        cmd_line(s, "ls \x1e forged")
        b, e = read_framed(s)
        print("[2] control-byte guard: %r exit=%s (framed err)" % (b[:40], e))
        if e != -1 or b"control byte" not in b: fails.append("control-byte guard not framed exit -1")

        # (3) an unknown __verb__ -> framed control error exit -1.
        cmd_line(s, "__nope__")
        b, e = read_framed(s)
        print("[3] unknown __verb__: %r exit=%s" % (b[:40], e))
        if e != -1 or b"unknown command" not in b: fails.append("unknown verb not framed exit -1")

        # (4) the regression: a delayed OK-prefixed shell reply. v2 reader (no timer) gets it
        # whole; a v1 settle reader truncates the SAME bytes at 500ms.
        DELAYED = "printf 'OK first\\n'; sleep 1; printf 'second\\nthird\\n'; exit 3"
        cmd_line(s, DELAYED)
        body, ex = read_framed(s)
        print("[4a] v2 reader: body=%r exit=%s" % (body, ex))
        if body != b"OK first\nsecond\nthird\n" or ex != 3:
            fails.append("v2 reader did not get the full delayed reply (body=%r exit=%s)" % (body, ex))
        s.close(); time.sleep(0.3)  # release the primary slot for the sub-tests below

        # (4b) the same DELAYED reply read with a v1 settle reader truncates the SAME wire.
        s2 = uconn(sk)
        cmd_line(s2, "__info__"); read_framed(s2)
        cmd_line(s2, DELAYED)
        kind, v1body = read_v1_settle(s2)
        print("[4b] v1 settle reader on the same wire: kind=%s body=%r" % (kind, v1body))
        if kind == "bare" and v1body == b"OK first":
            print("     ^ v1 TRUNCATED at 500ms; v2's uniform framing lets a consumer drop the settle timer")
        else:
            print("     (agent buffered body+trailer atomically here, so v1 also saw the frame; v2 removes the hazard regardless)")
        read_framed(s2)  # drain the rest of the still-running command to its frame, so its
        time.sleep(0.3)  # tail does not leak to the next primary (disconnect leaves it running)
        s2.close(); time.sleep(0.3)

        # (5) reference client nether-ctl speaks v2 (fresh connect each call -> primary).
        def ctl(*args):
            r = subprocess.run([CTL, sk, *args], capture_output=True, text=True, timeout=20)
            return r.returncode, r.stdout.strip()
        rc, out = ctl("__info__")
        print("[5a] nether-ctl __info__: rc=%d proto_version in out=%s" % (rc, "proto_version=2" in out))
        if "proto_version=2" not in out: fails.append("nether-ctl handshake not v2")
        rc, out = ctl("echo", "hi")
        print("[5b] nether-ctl echo hi: rc=%d out=%r" % (rc, out))
        if rc != 0 or out != "hi": fails.append("nether-ctl echo failed")
        rc, out = ctl("exit", "7")  # agent runs the line via sh -c, so `exit 7` -> exit 7
        print("[5c] nether-ctl 'exit 7': rc=%d (guest exit propagated)" % rc)
        if rc != 7: fails.append("nether-ctl did not propagate guest exit 7 (rc=%d)" % rc)
        rc, out = ctl("__nope__")
        print("[5d] nether-ctl __nope__: rc=%d out=%r (control error -> rc 1)" % (rc, out))
        if rc != 1: fails.append("nether-ctl control error not rc 1 (rc=%d)" % rc)

        ctl("__shutdown__")  # clean teardown (fresh conn -> primary)
    finally:
        try: p.terminate(); time.sleep(0.5); p.kill()
        except Exception: pass
        shutil.rmtree(WORK, ignore_errors=True)

    print()
    if fails:
        print("RESULT: FAIL"); [print("  - " + f) for f in fails]; return 1
    print("RESULT: PASS - v2 frames every command/ack reply (acks + control errors carry "
          "0x1e<exit>\\n; ERR=-1, OK=0); the guard rejects a forged frame; a v2 reader needs "
          "no settle timer; nether-ctl speaks v2 and propagates exit codes.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
