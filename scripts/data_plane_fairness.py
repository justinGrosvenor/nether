#!/usr/bin/env python3
# Does a large transfer on ONE data-plane conn starve concurrent conns (host-side HOL
# blocking)? Boot a VM with an in-guest server that serves /big (multi-MB) and /small (tiny),
# both concurrently. Conn A streams ~1.2 GB on /big; meanwhile conn B does /small in a loop
# and we measure B's latency. If B stays fast while A floods -> the data plane is FAIR (no HOL).
# NB use enough guest cores (cpus>=4) or the python big-send starves the /small handler in-GUEST
# (a guest-CPU artifact, not host vsock HOL - the whole point of this check is to tell them apart).
import os, socket, subprocess, sys, time, threading, shutil

NB = os.environ.get("NETHER_ROOT") or os.path.expanduser("~/nether"); BIN = NB + "/zig-out/bin/nether"; WORK = os.environ.get("NETHER_WORK", "/tmp/nfair"); RS = 0x1e

def uc(p, to=30):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(to); s.connect(p); return s

def un(b):
    o = bytearray(); e = False
    for x in b:
        if e: o.append(x ^ 0x40); e = False
        elif x == 0x1f: e = True
        else: o.append(x)
    return bytes(o)

def framed(s, to=8):
    s.settimeout(to); b = b""
    while RS not in b:
        c = s.recv(4096)
        if not c: return un(b), None
        b += c
    rs = b.index(RS)
    while b"\n" not in b[rs + 1:]: b += s.recv(64)
    return un(b[:rs]), int(b[rs + 1:b.index(b"\n", rs + 1)])

def cat(s, path):
    s.sendall(("cat %s 2>/dev/null; echo" % path).encode() + b"\n"); b, e = framed(s, 5); return b.decode(errors="replace").strip()

def L(cwd, log):
    return subprocess.Popen([BIN], cwd=cwd, stdin=subprocess.DEVNULL, stdout=open(os.path.join(cwd, log), "w"), stderr=subprocess.STDOUT)

# threaded in-guest server (ONE line - control proto is line-based, so lambdas not def):
# GET /big -> ~1.2 GB streamed (a reused 4 MiB buffer); anything else -> 'ok'. Thread per conn.
SRV = (
    "python3 -c \"import socket as k,threading as t;"
    "buf=b'X'*(4*1024*1024);"                       # 4 MiB, reused (no big alloc)
    "HB=b'HTTP/1.1 200 OK\\r\\nConnection: close\\r\\n\\r\\n';"
    "SM=b'HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\nConnection: close\\r\\n\\r\\nok';"
    "big=lambda c:(c.sendall(HB),[c.sendall(buf) for _ in range(300)],c.close());"   # ~1.2 GB streamed
    "sml=lambda c:(c.sendall(SM),c.close());"
    "h=lambda c:(big if b'/big' in c.recv(4096) else sml)(c);"
    "L=k.socket(k.AF_INET,k.SOCK_STREAM);L.setsockopt(k.SOL_SOCKET,k.SO_REUSEADDR,1);L.bind(('127.0.0.1',8080));L.listen(32);open('/tmp/up','w').write('UP');"
    "[t.Thread(target=h,args=(L.accept()[0],),daemon=True).start() for _ in iter(int,1)]"
    "\" >/tmp/srv.log 2>&1 &"
)

def http(dsock, path, read_all=True, to=30):
    t = time.time(); d = uc(dsock, to); d.sendall(("GET %s HTTP/1.0\r\n\r\n" % path).encode())
    n = 0
    while True:
        c = d.recv(65536)
        if not c: break
        n += len(c)
        if not read_all: break
    d.close(); return n, time.time() - t

def main():
    shutil.rmtree(WORK, ignore_errors=True); base = os.path.join(WORK, "b"); os.makedirs(base)
    os.symlink(NB + "/kernels", os.path.join(base, "kernels"))
    open(os.path.join(base, "nether.conf"), "w").write("control_socket=c.sock\ndata_socket=d.sock\napp_port=8080\nram_mb=768\ncpus=4\n")
    p = L(base, "boot.log"); csk = os.path.join(base, "c.sock"); dsk = os.path.join(base, "d.sock")
    try:
        t0 = time.time()
        while not os.path.exists(csk) and time.time() - t0 < 40: time.sleep(0.1)
        s = uc(csk)
        for _ in range(120):
            s.sendall(b"echo ready\n"); b, e = framed(s, 5)
            if b"ready" in b: break
            time.sleep(0.5)
        s.sendall(SRV.encode() + b"\n"); framed(s, 5)
        any("UP" in cat(s, "/tmp/up") or time.sleep(0.5) for _ in range(40))
        n0, l0 = http(dsk, "/small"); print("[warmup] /small = %dB (%.3fs)" % (n0, l0))

        # Baseline: /small latency with NO concurrent big transfer.
        base_lat = []
        for _ in range(20):
            _, l = http(dsk, "/small"); base_lat.append(l); time.sleep(0.02)
        print("[baseline] /small (idle): median %.4fs max %.4fs" % (sorted(base_lat)[len(base_lat)//2], max(base_lat)))

        # Under load: start a big transfer on conn A (background), hammer /small on conn B.
        big_done = {}
        def bigload():
            n, l = http(dsk, "/big"); big_done["n"] = n; big_done["l"] = l
        th = threading.Thread(target=bigload); th.start()
        time.sleep(0.05)  # let /big get going
        load_lat = []
        while th.is_alive() and len(load_lat) < 60:
            _, l = http(dsk, "/small"); load_lat.append(l); time.sleep(0.02)
        th.join()
        print("[under /big] big transfer: %dB in %.3fs (%.0f MB/s)" % (big_done.get("n",0), big_done.get("l",0), (big_done.get("n",0)/1e6)/big_done.get("l",1)))
        print("[under /big] /small samples: %s" % " ".join("%.3f"%x for x in load_lat))

        mx = max(load_lat) if load_lat else 0
        base_mx = max(base_lat)
        print()
        if mx > max(0.2, base_mx * 10):
            print("VERDICT: HOL BLOCKING CONFIRMED - /small max %.3fs under load vs %.3fs idle (a big transfer starves concurrent conns)." % (mx, base_mx))
        else:
            print("VERDICT: FAIR - /small stays responsive under a big transfer (max %.3fs vs idle %.3fs); no host-side HOL blocking." % (mx, base_mx))
        try: s.sendall(b"__shutdown__\n"); s.recv(64)
        except Exception: pass
    finally:
        try: p.terminate(); time.sleep(0.5); p.kill()
        except Exception: pass
        shutil.rmtree(WORK, ignore_errors=True)
    return 0

if __name__ == "__main__":
    sys.exit(main())
