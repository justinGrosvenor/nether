#!/usr/bin/env python3
# Multi-conn park proof: ONE VM with FOUR concurrent in-flight upstream requests, parked
# and revived. Exercises the rehydrate path beyond a single conn: hostConnsOnPort must
# enumerate all surviving egress conns, resumeEgress must revive each under its own id,
# and - the part that matters - each guest thread's blocking recv() must complete with
# ITS OWN reply. A cross-conn mixup (reply A landing in recv B) would pass a single-conn
# proof and corrupt real traffic.
import os, socket, subprocess, sys, time, threading, shutil

NB = os.environ.get("NETHER_ROOT") or os.path.expanduser("~/nether"); BIN = NB + "/zig-out/bin/nether"
WORK = os.environ.get("NETHER_WORK", "/tmp/npkm"); RS = 0x1e
TAGS = ["alpha", "bravo", "charlie", "delta"]  # one in-flight request per tag

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

def cat(s, path):
    return cmd(s, "cat %s 2>/dev/null; echo" % path, 8).strip()

def launch(cwd, log):
    return subprocess.Popen([BIN], cwd=cwd, stdin=subprocess.DEVNULL,
                            stdout=open(os.path.join(cwd, log), "w"), stderr=subprocess.STDOUT)

class Broker:
    """The platform: parks fresh conns (recording conn id -> request tag), and on a
    resume=1 dial replies with the TAG-SPECIFIC payload for that conn's request."""
    def __init__(self, path):
        self.path = path; self.lock = threading.Lock()
        self.parked = {}   # conn_id -> tag
        self.resumed = []  # tags revived, in arrival order
        self.errors = []
        if os.path.exists(path): os.unlink(path)
        self.ls = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.ls.bind(path); self.ls.listen(16)
        threading.Thread(target=self._loop, daemon=True).start()

    def _line(self, c):
        b = b""
        while not b.endswith(b"\n"):
            x = c.recv(1)
            if not x: return b
            b += x
        return b

    def _loop(self):
        while True:
            try: c, _ = self.ls.accept()
            except Exception: return
            threading.Thread(target=self._serve, args=(c,), daemon=True).start()

    def _serve(self, c):
        try:
            pre = self._line(c).decode(errors="replace").strip()
            kv = dict(t.split("=", 1) for t in pre.split() if "=" in t)
            cid = int(kv.get("conn", -1)); res = kv.get("resume") == "1"
            if res:
                with self.lock: tag = self.parked.get(cid)
                if tag is None:
                    self.errors.append("resume for unknown conn %d" % cid); c.close(); return
                with self.lock: self.resumed.append(tag)
                c.sendall(("REPLY-FOR-%s\n" % tag).encode())  # THIS conn's reply, nobody else's
                try: c.recv(4096)
                except Exception: pass
                c.close(); return
            c.settimeout(10)
            req = c.recv(4096).decode(errors="replace")
            tag = next((t for t in TAGS if t in req), None)
            if tag is None:
                self.errors.append("request with no tag: %r" % req); c.close(); return
            with self.lock: self.parked[cid] = tag
            print("  [broker] conn=%d parked (tag=%s)" % (cid, tag))
            try: c.recv(4096)  # hold until the VM dies
            except Exception: pass
        except Exception as ex:
            self.errors.append("broker: %r" % ex)

# All four requesters in ONE guest command: each thread opens its own conn to the egress
# port, sends a tagged request, blocks in recv(), and writes the reply to /tmp/r-<tag>.
REQ4 = (
    "python3 -c \"import socket as k,threading as t;"
    "go=lambda g:(lambda s:(s.sendall(('GET /'+g+'\\n').encode()),"
    "open('/tmp/r-'+g,'wb').write(s.recv(65536))))(k.create_connection(('127.0.0.1',9090)));"
    "ts=[t.Thread(target=go,args=(g,)) for g in ['%s']];"
    "[x.start() for x in ts];[x.join() for x in ts];print('all-done')\""
    " >/tmp/req.log 2>&1 &"
) % "','".join(TAGS)

def main():
    if not os.path.exists(BIN): print("FAIL: build %s first" % BIN); return 1
    shutil.rmtree(WORK, ignore_errors=True)
    base = os.path.join(WORK, "b"); fork = os.path.join(WORK, "f")
    os.makedirs(base); os.makedirs(fork)
    os.symlink(NB + "/kernels", os.path.join(base, "kernels"))
    esock = os.path.join(WORK, "e.sock")
    open(os.path.join(base, "nether.conf"), "w").write(
        "control_socket=c.sock\negress_socket=%s\negress_port=9090\nram_mb=512\ncpus=2\n" % esock)
    broker = Broker(esock)
    procs = []; fails = []
    try:
        bp = launch(base, "boot.log"); procs.append(bp)
        csk = os.path.join(base, "c.sock")
        t0 = time.time()
        while not os.path.exists(csk) and time.time() - t0 < 40: time.sleep(0.0003)
        s = uc(csk)
        for _ in range(120):
            if "ready" in cmd(s, "echo ready", 5): break
            time.sleep(0.5)

        # 1. Four concurrent in-flight upstreams from one guest.
        cmd(s, REQ4, 15)
        t0 = time.time()
        while len(broker.parked) < len(TAGS) and time.time() - t0 < 20: time.sleep(0.0003)
        if len(broker.parked) < len(TAGS):
            fails.append("only %d/%d conns parked" % (len(broker.parked), len(TAGS))); raise SystemExit
        ids = sorted(broker.parked)
        print("[park] %d conns in flight (ids %s), all guest threads blocked in recv()" % (len(ids), ids))
        if len(set(broker.parked.values())) != len(TAGS): fails.append("tag collision in parked conns")
        time.sleep(1.0)

        # 2. Park the lot in one command.
        rep = cmd(s, "__park__ multi.snap", 90)
        print("[park] %s" % rep.strip()[:90])
        if not rep.startswith("OK parked"): fails.append("__park__ failed: %r" % rep)
        try:
            if bp.wait(timeout=10) != 0: fails.append("park exit != 0")
        except subprocess.TimeoutExpired:
            fails.append("no self-exit after park"); bp.kill()

        # 3. Wake. ALL FOUR conns must revive and each recv must get ITS OWN reply.
        open(os.path.join(fork, "nether.conf"), "w").write(
            "restore=1\nrestore_from=%s\ncontrol_socket=f.sock\negress_socket=%s\n"
            % (os.path.join(base, "multi.snap"), esock))
        t_r = time.time()
        fp = launch(fork, "fork.log"); procs.append(fp)
        fsk = os.path.join(fork, "f.sock")
        while not os.path.exists(fsk) and time.time() - t_r < 30: time.sleep(0.0003)
        fs = uc(fsk)
        got = {}
        while time.time() - t_r < 30 and len(got) < len(TAGS):
            for g in TAGS:
                if g not in got:
                    v = cat(fs, "/tmp/r-%s" % g)
                    if v: got[g] = v
            time.sleep(0.0003)
        dt = time.time() - t_r
        print("[wake] %.3fs; replies: %s" % (dt, got))
        flog = open(os.path.join(fork, "fork.log")).read()
        if ("revived %d/%d" % (len(TAGS), len(TAGS))) not in flog:
            fails.append("fork log missing 'revived %d/%d' (%s)" % (len(TAGS), len(TAGS),
                [l for l in flog.splitlines() if "egress" in l]))
        else:
            print("[wake] fork log: revived %d/%d" % (len(TAGS), len(TAGS)))
        for g in TAGS:
            want = "REPLY-FOR-%s" % g
            if got.get(g, "") != want:
                fails.append("conn mixup: /tmp/r-%s = %r, want %r" % (g, got.get(g), want))
        if not fails: print("[wake] every thread's recv() got ITS OWN reply - no cross-conn mixups")
        if "all-done" not in cat(fs, "/tmp/req.log"):
            fails.append("guest requester did not run to completion")
        try: cmd(fs, "__shutdown__", 5)
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
    if broker.errors: fails.extend(broker.errors)
    print()
    if fails:
        print("RESULT: FAIL"); [print("  - " + f) for f in fails]; return 1
    print("RESULT: PASS - four concurrent in-flight upstreams parked in one VM and ALL revived on")
    print("wake, each blocking recv() completing with its own conn's reply. The rehydrate path is")
    print("correct beyond a single conn: no drops, no cross-conn mixups.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
