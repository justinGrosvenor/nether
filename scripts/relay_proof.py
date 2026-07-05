#!/usr/bin/env python3
# Live proof of the two relay/pipe audit fixes (each on its own fresh VM):
#  #1 a primary that DISCONNECTS mid-command must not leak its tail into the next primary:
#     reconnect and the new primary gets ITS OWN clean reply, not the old command's output.
#  #3 a WEDGED control consumer must not stall the vCPU: while a primary floods UNCAPPED
#     output and stops reading, the data plane (same device thread) stays responsive (~ms).
import os, socket, subprocess, sys, time, shutil

NB = os.path.expanduser("~/nether"); BIN = NB + "/zig-out/bin/nether"; WORK = "/tmp/nrelay"; RS = 0x1e

def uc(p, to=15):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(to); s.connect(p); return s

def un(b):
    o = bytearray(); e = False
    for x in b:
        if e: o.append(x ^ 0x40); e = False
        elif x == 0x1f: e = True
        else: o.append(x)
    return bytes(o)

def framed(s, to):
    s.settimeout(to); b = b""
    try:
        while RS not in b:
            c = s.recv(4096)
            if not c: return un(b), None
            b += c
        rs = b.index(RS)
        while b"\n" not in b[rs + 1:]:
            c = s.recv(64)
            if not c: break
            b += c
        return un(b[:rs]), int(b[rs + 1:b.index(b"\n", rs + 1)])
    except socket.timeout:
        return b, "TIMEOUT"

def meta(s, line, to=60):
    s.settimeout(to); s.sendall(line.encode() + b"\n"); b = b""
    while b"\n" not in b:
        c = s.recv(256)
        if not c: break
        b += c
    return b.decode(errors="replace").strip()

def cat(s, path):
    s.sendall(("cat %s 2>/dev/null; echo" % path).encode() + b"\n"); b, e = framed(s, 5); return b.decode(errors="replace").strip()

def L(cwd, log):
    return subprocess.Popen([BIN], cwd=cwd, stdin=subprocess.DEVNULL, stdout=open(os.path.join(cwd, log), "w"), stderr=subprocess.STDOUT)

SRV = ("python3 -c \"import socket as k,threading as t;"
       "L=k.socket(k.AF_INET,k.SOCK_STREAM);L.setsockopt(k.SOL_SOCKET,k.SO_REUSEADDR,1);L.bind(('127.0.0.1',8080));L.listen(16);open('/tmp/up','w').write('UP');"
       "h=lambda c:(c.recv(4096),c.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\n\\r\\nOK'),c.close());"
       "[t.Thread(target=h,args=(L.accept()[0],),daemon=True).start() for _ in iter(int,1)]\" >/tmp/s.log 2>&1 &")

def curl(dsock, to=6):
    t = time.time(); d = uc(dsock, to); d.sendall(b"GET / HTTP/1.0\r\n\r\n"); r = b""
    while True:
        c = d.recv(1024)
        if not c: break
        r += c
    d.close(); return b"200 OK" in r, time.time() - t

def boot(name, extra=""):
    d = os.path.join(WORK, name); os.makedirs(d)
    os.symlink(NB + "/kernels", os.path.join(d, "kernels"))
    open(os.path.join(d, "nether.conf"), "w").write(
        "control_socket=c.sock\ndata_socket=d.sock\napp_port=8080\nram_mb=512\ncpus=1\n" + extra)
    p = L(d, "boot.log")
    csk = os.path.join(d, "c.sock")
    t0 = time.time()
    while not os.path.exists(csk) and time.time() - t0 < 40: time.sleep(0.1)
    s = uc(csk)
    for _ in range(120):
        s.sendall(b"echo ready\n"); b, e = framed(s, 5)
        if b"ready" in b: break
        time.sleep(0.5)
    return p, csk, os.path.join(d, "d.sock"), s

def main():
    shutil.rmtree(WORK, ignore_errors=True); os.makedirs(WORK)
    procs = []; fails = []
    try:
        # ---- #1: disconnect mid-command; the next primary must be clean. ----
        p1, csk, dsk, s = boot("v1"); procs.append(p1)
        A2 = s  # boot's own connection is already the primary (it drove "echo ready")
        A2.sendall(b"for i in 1 2 3 4 5 6; do echo OLD-$i; sleep 0.3; done; echo OLD-END\n")
        time.sleep(0.5)  # OLD-1/OLD-2 stream
        part = A2.recv(4096)
        print("[#1] primary A read partial old output: %r" % part[:24])
        A2.close()  # DISCONNECT mid-command (OLD keeps running in the guest)
        time.sleep(0.2)
        B = uc(csk); B.sendall(b"__info__\n"); framed(B, 8)  # B = new primary
        B.sendall(b"echo NEWCMD\n")
        body, ex = framed(B, 10)  # waits for OLD to finish in the guest, then NEWCMD runs
        print("[#1] new primary B drive 'echo NEWCMD' -> body=%r exit=%s" % (body, ex))
        if body != b"NEWCMD\n" or ex != 0 or b"OLD" in body:
            fails.append("#1 relay leak: new primary got %r (expected clean NEWCMD)" % body)
        B.close()
        try: meta(uc(csk, 5), "__shutdown__", 5)
        except Exception: pass
        time.sleep(0.5)

        # ---- #3: a wedged UNCAPPED flood must not stall the vCPU (data plane stays live). ----
        p3, csk3, dsk3, s3 = boot("v3", "max_output_bytes=0\n"); procs.append(p3)
        s3.sendall(SRV.encode() + b"\n"); framed(s3, 5)
        any("UP" in cat(s3, "/tmp/up") or time.sleep(0.5) for _ in range(40))
        ok, lat = curl(dsk3); print("[#3] warmup data plane serves=%s (%.3fs)" % (ok, lat))
        s3.close(); time.sleep(0.3)
        A = uc(csk3); A.sendall(b"__info__\n"); framed(A, 8)  # A = primary
        A.sendall(b"head -c 800000 /dev/zero\n")  # ~800 KB (exceeds the pipe+socket buffers) UNCAPPED, LOW guest CPU; A stops reading -> wedge
        time.sleep(0.2)
        lats = []; t0 = time.time()
        while time.time() - t0 < 3.0:
            try: ok, lat = curl(dsk3, 6); lats.append(lat)
            except Exception: lats.append(6.0)
            time.sleep(0.1)
        mx = max(lats); print("[#3] wedged flood: %d data-plane curls, max latency %.3fs (want < 0.5s)" % (len(lats), mx))
        print("[#3] per-curl latencies: %s" % " ".join("%.2f" % x for x in lats))
        if mx >= 0.5: fails.append("#3 vCPU stalled: data-plane max latency %.3fs under a wedged consumer" % mx)
        # after the wedge the flooder must have been dropped -> a fresh primary can drive
        try: A.close()
        except Exception: pass
        time.sleep(0.3)
        C = uc(csk3); C.sendall(b"__info__\n"); framed(C, 8); C.sendall(b"echo AFTER\n"); ab, ae = framed(C, 8)
        print("[#3] fresh primary after wedge: %r exit=%s (flooder was dropped)" % (ab, ae))
        if ab != b"AFTER\n": fails.append("#3 flooder not dropped: fresh primary got %r" % ab)
    finally:
        for p in procs:
            try: p.terminate()
            except Exception: pass
        time.sleep(0.5)
        for p in procs:
            try: p.kill()
            except Exception: pass
        shutil.rmtree(WORK, ignore_errors=True)
    print()
    if fails:
        print("RESULT: FAIL"); [print("  - " + f) for f in fails]; return 1
    print("RESULT: PASS - a mid-command disconnect no longer leaks its tail into the next primary, "
          "and a wedged control consumer no longer stalls the vCPU (data plane stays responsive; flooder dropped).")
    return 0

if __name__ == "__main__":
    sys.exit(main())
