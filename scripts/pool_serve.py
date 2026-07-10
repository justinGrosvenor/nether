#!/usr/bin/env python3
# Warm-VM POOL proof (park-concurrency 1c, nether side).
#
# A supervisor pre-forks a buffer of warm Nether microVMs from a
# baked base and hands one out per tenant on demand. This harness proves the nether-side
# mechanics that pool rests on, live on HVF: bake one base whose in-guest HTTP server is
# running, pre-fork N warm VMs from it, and show that
#   - every fork reaches "serving" and reports data_plane=on via __info__ (the readiness
#     check the supervisor uses),
#   - checkout is INSTANT because the VM is already warm - contrast a cold on-demand fork,
#   - all N serve concurrently, each the SAME warm base server instance (CoW), and
#   - the pool refills (fork one more) in fork-latency.
#
# Run: python3 scripts/pool_serve.py [N]      (requires a codesigned HVF nether binary)
import os, socket, subprocess, sys, time, threading, shutil

NB = os.environ.get("NETHER_ROOT") or os.path.expanduser("~/nether")
BIN = NB + "/zig-out/bin/nether"
# AF_UNIX paths cap at ~104 bytes on macOS and a scratch path is longer, so the run dir
# (which holds the control/data sockets) must live under a short path.
WORK = os.environ.get("NETHER_WORK", "/tmp/nvp")
N = int(sys.argv[1]) if len(sys.argv) > 1 else 4
RAM_MB = 512  # >= the runtime-image RAM floor (a 64 MiB initramfs needs ~384; see main.zig guard)

def uconn(path, to=20):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(to); s.connect(path); return s

def frame(s):
    b = b""
    while b"\x1e" not in b: b += s.recv(4096)
    return b

def cmd(s, line):
    s.sendall(line.encode() + b"\n"); return frame(s).split(b"\x1e")[0].decode(errors="replace")

def meta(s, line, to=60):
    old = s.gettimeout(); s.settimeout(to)
    s.sendall(line.encode() + b"\n"); b = b""
    while b"\n" not in b:
        c = s.recv(256)
        if not c: break
        b += c
    s.settimeout(old); return b.decode(errors="replace").strip()

def cat(s, path):
    return cmd(s, "cat %s 2>/dev/null; echo" % path).strip()

def info(sock_path):
    s = uconn(sock_path, 8); r = cmd(s, "__info__"); s.close(); return r

def launch(cwd, log):
    f = open(os.path.join(cwd, log), "w")
    return subprocess.Popen([BIN], cwd=cwd, stdin=subprocess.DEVNULL, stdout=f, stderr=subprocess.STDOUT)

def hit(path, to=15):
    d = uconn(path, to); d.sendall(b"GET / HTTP/1.0\r\n\r\n"); buf = b""
    while True:
        try: c = d.recv(4096)
        except Exception: break
        if not c: break
        buf += c
    d.close()
    body = buf.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in buf else buf
    return body.decode(errors="replace").strip()

def parse(resp):
    iid = None
    for tok in (resp or "").split():
        if tok.startswith("IID="): iid = tok[4:]
    return iid

# In-guest tenant HTTP server on 127.0.0.1:8080 (one line; control proto is line-based).
SRV = (
    "python3 -c \""
    "import socket as k,threading as t,random,itertools as z;"
    "ID=str(random.randint(10**8,10**9));open('/tmp/iid','w').write(ID);"
    "L=k.socket(k.AF_INET,k.SOCK_STREAM);L.setsockopt(k.SOL_SOCKET,k.SO_REUSEADDR,1);"
    "L.bind(('127.0.0.1',8080));L.listen(32);cnt=z.count(1);"
    "mk=lambda n:('IID=%s REQ=%d\\n'%(ID,n)).encode();"
    "snd=lambda s,b:s.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Length: '+str(len(b)).encode()+b'\\r\\nConnection: close\\r\\n\\r\\n'+b);"
    "h=lambda s:(s.recv(4096),snd(s,mk(next(cnt))),s.close());"
    "open('/tmp/up','w').write('UP');"
    "[t.Thread(target=h,args=(L.accept()[0],),daemon=True).start() for _ in iter(int,1)]"
    "\" >/tmp/srv.log 2>&1 &"
)

def vm_conf(snap):
    return "restore=1\nrestore_from=%s\ncontrol_socket=c.sock\ndata_socket=d.sock\napp_port=8080\nram_mb=%d\n" % (snap, RAM_MB)

def fork_vm(idx, snap):
    """Launch one warm fork; return (dir, proc, t_launch)."""
    d = os.path.join(WORK, "vm%d" % idx); os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "nether.conf"), "w").write(vm_conf(snap))
    t0 = time.time()
    p = launch(d, "vm.log")
    return d, p, t0

def wait_serving(d, t0, budget=40):
    """Poll the VM's data socket until it serves; return (resp, latency) or (None, budget)."""
    ds = os.path.join(d, "d.sock")
    while time.time() - t0 < budget:
        if os.path.exists(ds):
            try:
                r = hit(ds, 5)
                if r: return r, time.time() - t0
            except Exception: pass
        time.sleep(0.03)
    return None, time.time() - t0

def main():
    if not os.path.exists(BIN):
        print("FAIL: %s not built" % BIN); return 1
    shutil.rmtree(WORK, ignore_errors=True)
    base = os.path.join(WORK, "base"); os.makedirs(base)
    os.symlink(NB + "/kernels", os.path.join(base, "kernels"))
    open(os.path.join(base, "nether.conf"), "w").write(
        "control_socket=base.sock\ndata_socket=base.data\napp_port=8080\nram_mb=%d\ncpus=1\n" % RAM_MB)

    procs = []; fails = []
    try:
        # 1. Bake the base: boot, start the tenant server, snapshot it warm.
        bp = launch(base, "boot.log"); procs.append(bp)
        t0 = time.time()
        while not os.path.exists(os.path.join(base, "base.sock")) and time.time() - t0 < 40: time.sleep(0.1)
        s = uconn(os.path.join(base, "base.sock")); cmd(s, "__info__")
        for _ in range(120):
            if "ready" in cmd(s, "echo ready"): break
            time.sleep(0.5)
        cmd(s, SRV)
        up = any("UP" in cat(s, "/tmp/up") or time.sleep(0.5) for _ in range(40))
        base_iid = cat(s, "/tmp/iid")
        rep = meta(s, "__snapshot__ base.snap")
        snap = os.path.join(base, "base.snap")
        print("[bake] base server UP=%s IID=%s snapshot=%s" % (up, base_iid, rep.strip()))
        if "OK" not in rep or not up: fails.append("base bake failed")

        # 2. Pre-fork the warm pool: N forks in parallel; measure each to first-serve.
        t_pool = time.time()
        forks = [fork_vm(i, snap) for i in range(N)]
        procs += [p for (_, p, _) in forks]
        warmed = []
        for i, (d, p, tl) in enumerate(forks):
            r, dt = wait_serving(d, tl)
            warmed.append((d, r, dt))
            if not r or parse(r) != base_iid: fails.append("pool VM %d never served the warm base server" % i)
        pool_dt = time.time() - t_pool
        lat = [dt for (_, _, dt) in warmed]
        print("[pool] %d/%d warm VMs serving; wall=%.2fs, per-VM warm avg=%.3fs max=%.3fs (all IID=%s)"
              % (sum(1 for _, r, _ in warmed if parse(r) == base_iid), N, pool_dt,
                 sum(lat)/len(lat) if lat else 0, max(lat) if lat else 0, base_iid))

        # 3. Readiness: every warm fork advertises data_plane=on via __info__ (the restore
        #    path now sets app_port, so a supervisor's health check sees the data plane).
        dp_on = 0
        for d, _, _ in warmed:
            r = info(os.path.join(d, "c.sock"))
            if "data_plane=on" in r: dp_on += 1
        print("[ready] __info__ data_plane=on: %d/%d forks" % (dp_on, N))
        if dp_on != N: fails.append("only %d/%d forks advertise data_plane=on" % (dp_on, N))

        # 4. The pool's value: checkout is instant (VM already warm) vs a cold on-demand fork.
        t = time.time(); r = hit(os.path.join(warmed[0][0], "d.sock")); checkout = time.time() - t
        cd, cp, ct = fork_vm(N, snap); procs.append(cp)
        cr, cold = wait_serving(cd, ct)
        print("[value] checkout from warm pool=%.4fs vs cold on-demand fork=%.3fs (pool hides the fork)"
              % (checkout, cold))
        if not cr or parse(cr) != base_iid: fails.append("cold on-demand fork did not serve")

        # 5. Concurrency: hand out all N at once; each serves the one shared warm server.
        res = [None] * N
        def worker(i):
            for _ in range(2):
                try:
                    v = hit(os.path.join(warmed[i][0], "d.sock"), 15)
                    if parse(v) == base_iid: res[i] = v; return
                except Exception as e: res[i] = "ERR:%s" % e
        ths = [threading.Thread(target=worker, args=(i,)) for i in range(N)]
        [th.start() for th in ths]; [th.join() for th in ths]
        served = sum(1 for x in res if parse(x) == base_iid)
        print("[conc] %d/%d pool VMs served concurrently by IID=%s" % (served, N, base_iid))
        if served != N: fails.append("concurrency: only %d/%d pool VMs served" % (served, N))

        # 6. Refill: fork one replacement to top the pool back up.
        rd, rp, rt = fork_vm(N + 1, snap); procs.append(rp)
        rr, refill = wait_serving(rd, rt)
        print("[refill] replacement warm in %.3fs (serving=%s)" % (refill, parse(rr) == base_iid))
        if not rr or parse(rr) != base_iid: fails.append("refill fork did not serve")

        try: meta(s, "__shutdown__", 5)
        except Exception: pass
    finally:
        for p in procs:
            try: p.terminate()
            except Exception: pass
        time.sleep(0.5)
        for p in procs:
            try: p.kill()
            except Exception: pass

    print()
    if fails:
        print("RESULT: FAIL"); [print("  - " + f) for f in fails]; return 1
    print("RESULT: PASS - a pool of %d warm forks from one base, each serving the shared warm "
          "server; instant checkout, data_plane=on, concurrent, refillable." % N)
    return 0

if __name__ == "__main__":
    sys.exit(main())
