#!/usr/bin/env python3
# Park-while-awaiting-upstream proof (the egress plane end to end, live on HVF).
#
# The claim: a guest running ORDINARY blocking code can make an outbound request through
# the egress plane, be snapshotted and KILLED mid-recv() while the platform holds the
# upstream, and - when the reply arrives - a restored fork completes the SAME blocking
# recv() with the reply bytes. Nobody's VM is running while the upstream is slow.
#
# Mechanics under test:
#   guest app -> 127.0.0.1:<egress_port> -> in-guest forwarder (reverse mode) ->
#   guest->host vsock conn (port 5002, pure in-memory state, SURVIVES the snapshot) ->
#   nether dials egress_socket with preamble `NETHER-EGRESS v1 conn=<id> resume=<0|1>`.
#   On restore, nether re-dials with resume=1 and the same conn id; this harness (playing
#   the platform) re-splices the parked "upstream reply" into it.
#
# Proves: (1) a fresh egress conn round-trips (the egress plane works at all);
#         (2) the parked conn's id is announced, the VM dies, and the restored fork
#             revives it (fork log: "revived 1/1");
#         (3) the guest's ORIGINAL blocking recv() completes with the correct bytes;
#         (4) park->wake latency is reported.
import os, socket, subprocess, sys, time, threading, shutil

NB = os.path.expanduser("~/nether"); BIN = NB + "/zig-out/bin/nether"
WORK = "/tmp/npk"  # AF_UNIX paths cap ~104B on macOS: keep it short
RS = 0x1e
NONCE = "PARKED-REPLY-7f3a9c"

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

class EgressBroker:
    """Plays the PLATFORM: owns the egress_socket listener and the (pretend) upstream.
    Fresh conns (resume=0): record the request, hold the conn open, never reply - the
    upstream is slow. /quick requests get an instant reply (sanity path). Resumed conns
    (resume=1): look up the parked request by conn id and deliver the reply."""
    def __init__(self, path):
        self.path = path; self.lock = threading.Lock()
        self.fresh = {}    # conn_id -> request bytes (parked, awaiting reply)
        self.resumed = {}  # conn_id -> True once the resume dial arrived
        self.errors = []
        if os.path.exists(path): os.unlink(path)
        self.ls = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.ls.bind(path); self.ls.listen(16)
        threading.Thread(target=self._accept_loop, daemon=True).start()

    def _readline(self, c):
        b = b""
        while not b.endswith(b"\n"):
            x = c.recv(1)
            if not x: return b
            b += x
        return b

    def _accept_loop(self):
        while True:
            try: c, _ = self.ls.accept()
            except Exception: return
            threading.Thread(target=self._serve, args=(c,), daemon=True).start()

    def _serve(self, c):
        try:
            pre = self._readline(c).decode(errors="replace").strip()
            kv = dict(t.split("=", 1) for t in pre.split() if "=" in t)
            cid = int(kv.get("conn", -1)); res = kv.get("resume") == "1"
            if not pre.startswith("NETHER-EGRESS v1") or cid < 0:
                self.errors.append("bad preamble: %r" % pre); c.close(); return
            print("  [broker] conn=%d resume=%d dialed" % (cid, res))
            if res:
                with self.lock:
                    req = self.fresh.get(cid); self.resumed[cid] = True
                if req is None:
                    self.errors.append("resume for unknown conn %d" % cid); c.close(); return
                # The parked upstream's reply "arrives" into the revived conn.
                c.sendall(("REPLY %s\n" % NONCE).encode())
                # hold open; the guest closes its side when done
                try: c.recv(4096)
                except Exception: pass
                c.close(); return
            # fresh conn: read the request
            c.settimeout(10)
            req = c.recv(4096)
            if b"/quick" in req:
                c.sendall(b"REPLY quick-ok\n")
                try: c.recv(4096)
                except Exception: pass
                c.close(); return
            with self.lock: self.fresh[cid] = req  # slow upstream: park it, NO reply
            print("  [broker] conn=%d parked awaiting upstream (req=%r)" % (cid, req.strip()))
            # keep the socket open until the VM dies (nether's side closes with the process)
            try: c.recv(4096)
            except Exception: pass
        except Exception as ex:
            self.errors.append("broker: %r" % ex)

# Guest one-liners: ordinary blocking sockets against 127.0.0.1:<egress_port>.
QUICK = ("python3 -c \"import socket;s=socket.create_connection(('127.0.0.1',9090));"
         "s.sendall(b'GET /quick\\n');d=s.recv(65536);open('/tmp/quick','wb').write(d)\""
         " >/tmp/q.log 2>&1")
SLOW = ("python3 -c \"import socket;s=socket.create_connection(('127.0.0.1',9090));"
        "s.sendall(b'GET /slow\\n');d=s.recv(65536);open('/tmp/reply','wb').write(d);print('done')\""
        " >/tmp/req.log 2>&1 &")

def main():
    if not os.path.exists(BIN): print("FAIL: build %s first" % BIN); return 1
    shutil.rmtree(WORK, ignore_errors=True)
    base = os.path.join(WORK, "b"); fork = os.path.join(WORK, "f")
    os.makedirs(base); os.makedirs(fork)
    os.symlink(NB + "/kernels", os.path.join(base, "kernels"))
    esock = os.path.join(WORK, "e.sock")
    open(os.path.join(base, "nether.conf"), "w").write(
        "control_socket=c.sock\negress_socket=%s\negress_port=9090\nram_mb=512\ncpus=2\n" % esock)
    broker = EgressBroker(esock)
    procs = []; fails = []
    try:
        # 1. Boot; wait for the agent.
        bp = launch(base, "boot.log"); procs.append(bp)
        csk = os.path.join(base, "c.sock")
        t0 = time.time()
        while not os.path.exists(csk) and time.time() - t0 < 40: time.sleep(0.1)
        s = uc(csk)
        for _ in range(120):
            if "ready" in cmd(s, "echo ready", 5): break
            time.sleep(0.5)
        info = cmd(s, "__info__", 5)
        eg = [l for l in info.splitlines() if l.startswith("egress_plane=")]
        print("[info] %s" % (eg[0] if eg else "egress_plane MISSING"))
        if not eg or eg[0] != "egress_plane=on": fails.append("__info__ does not advertise egress_plane=on")

        # 2. Sanity: a fresh egress conn round-trips (guest outbound -> broker -> reply).
        cmd(s, QUICK, 20)
        q = cat(s, "/tmp/quick")
        print("[quick] guest got: %r" % q)
        if "quick-ok" not in q: fails.append("fresh egress round-trip failed: %r" % q)

        # 3. The slow request: guest blocks in recv(); broker parks the conn (no reply).
        cmd(s, SLOW, 10)
        t0 = time.time()
        while not broker.fresh and time.time() - t0 < 15: time.sleep(0.05)
        if not broker.fresh:
            fails.append("broker never saw the slow request"); raise SystemExit
        parked_id = [k for k in broker.fresh if b"/slow" in broker.fresh[k]][0]
        print("[park] guest awaiting upstream on conn=%d; /tmp/reply=%r (must be empty)" % (parked_id, cat(s, "/tmp/reply")))
        time.sleep(1.0)  # let the guest settle into recv()/WFI

        # 4. Snapshot + KILL. The VM ceases to exist; the broker holds the upstream.
        rep = cmd(s, "__snapshot__ park.snap", 90)
        print("[snap] %s" % rep.strip().splitlines()[-1] if rep else "[snap] no reply")
        if "OK" not in rep: fails.append("__snapshot__ failed: %r" % rep)
        bp.terminate(); time.sleep(0.3); bp.kill()
        print("[kill] VM process dead; guest exists only as park.snap + the broker's parked conn")
        t_parked = time.time()

        # 5. The upstream is slow... (nobody is paying for RAM/CPU right now)
        time.sleep(2.0)

        # 6. The reply "arrives" -> restore the fork. Nether revives the parked conn
        #    (resume=1, same id); the broker replies into it; the guest's ORIGINAL
        #    blocking recv() completes.
        open(os.path.join(fork, "nether.conf"), "w").write(
            "restore=1\nrestore_from=%s\ncontrol_socket=f.sock\negress_socket=%s\n"
            % (os.path.join(base, "park.snap"), esock))
        t_restore = time.time()
        fp = launch(fork, "fork.log"); procs.append(fp)
        fsk = os.path.join(fork, "f.sock")
        while not os.path.exists(fsk) and time.time() - t_restore < 30: time.sleep(0.05)
        fs = uc(fsk)
        got = ""
        while time.time() - t_restore < 25:
            got = cat(fs, "/tmp/reply")
            if NONCE in got: break
            time.sleep(0.1)
        t_done = time.time()
        print("[wake] guest /tmp/reply: %r" % got)
        print("[wake] restore->reply-delivered: %.3fs (parked %.1fs total)" % (t_done - t_restore, t_done - t_parked))
        if NONCE not in got:
            fails.append("guest recv() did not complete with the parked reply (got %r)" % got)
        if parked_id not in broker.resumed:
            fails.append("broker never saw resume=1 for conn %d" % parked_id)
        flog = open(os.path.join(fork, "fork.log")).read()
        if "revived 1/1" not in flog: fails.append("fork log missing 'revived 1/1' (got: %s)"
            % ([l for l in flog.splitlines() if "egress" in l] or "no egress lines"))
        req_log = cat(fs, "/tmp/req.log")
        print("[wake] guest requester log: %r (blocking code ran to completion)" % req_log)

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
    print("RESULT: PASS - ordinary blocking guest code parked mid-recv() (VM killed), upstream held by")
    print("the platform, and a restored fork completed the SAME recv() with the reply. Park-while-")
    print("awaiting-upstream is real.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
