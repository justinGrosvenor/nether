#!/usr/bin/env python3
# Does the per-VM data-plane bandwidth cap (data_rate_kbps) actually pace a flooding tenant?
# Boot a VM with an in-guest server (/big -> a fixed 8 MiB blob, /small -> 'ok'). Run it TWICE:
#   1. UNCAPPED (data_rate_kbps=0): measure /big throughput -> the line-rate baseline.
#   2. CAPPED  (data_rate_kbps=8000 = 1 MB/s): measure /big throughput -> must land at ~the cap,
#      AND a concurrent /small must stay responsive (the aggregate cap must not starve small reqs).
# PROVES: the cap paces upstream throughput to ~data_rate_kbps (and << uncapped), __info__ advertises
# it, and pacing (delivery-credit backpressure, guest stalls at its 256 KiB window) drops no bytes.
# The cap is per-VM (each DataBridge has its own token bucket), so a capped tenant cannot affect
# another VM - that isolation is structural (separate process, separate bucket).
import os, socket, subprocess, sys, time, threading, shutil

NB = os.path.expanduser("~/nether"); BIN = NB + "/zig-out/bin/nether"; WORK = "/tmp/npace"; RS = 0x1e
CAP_KBPS = 8000            # 8000 kbps * 125 = 1,000,000 B/s = 1.0 MB/s
CAP_MBps = CAP_KBPS * 125 / 1e6
BIG_MIB = 8               # /big streams a fixed 8 MiB so the transfer terminates and we can time it

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

# in-guest server (ONE line - control proto is line-based): GET /big -> BIG_MIB of 'X' (1 MiB sends),
# anything else -> 'ok'. Thread per conn.
SRV = (
    "python3 -c \"import socket as k,threading as t;"
    "buf=b'X'*(1024*1024);"
    "HB=b'HTTP/1.1 200 OK\\r\\nConnection: close\\r\\n\\r\\n';"
    "SM=b'HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\nConnection: close\\r\\n\\r\\nok';"
    "big=lambda c:(c.sendall(HB),[c.sendall(buf) for _ in range(%d)],c.close());"
    "sml=lambda c:(c.sendall(SM),c.close());"
    "h=lambda c:(big if b'/big' in c.recv(4096) else sml)(c);"
    "L=k.socket(k.AF_INET,k.SOCK_STREAM);L.setsockopt(k.SOL_SOCKET,k.SO_REUSEADDR,1);L.bind(('127.0.0.1',8080));L.listen(32);open('/tmp/up','w').write('UP');"
    "[t.Thread(target=h,args=(L.accept()[0],),daemon=True).start() for _ in iter(int,1)]"
    "\" >/tmp/srv.log 2>&1 &"
) % BIG_MIB

def http(dsock, path, to=60):
    t = time.time(); d = uc(dsock, to); d.sendall(("GET %s HTTP/1.0\r\n\r\n" % path).encode())
    n = 0
    while True:
        c = d.recv(262144)
        if not c: break
        n += len(c)
    d.close(); return n, time.time() - t

def info_rate(s):
    s.sendall(b"__info__\n"); b, e = framed(s, 5)
    for ln in b.decode(errors="replace").splitlines():
        if ln.startswith("data_rate_kbps="): return int(ln.split("=", 1)[1])
    return None

def run(cap_kbps):
    tag = "CAPPED %d kbps" % cap_kbps if cap_kbps else "UNCAPPED"
    print("\n=== run: %s ===" % tag)
    shutil.rmtree(WORK, ignore_errors=True); base = os.path.join(WORK, "b"); os.makedirs(base)
    os.symlink(NB + "/kernels", os.path.join(base, "kernels"))
    conf = "control_socket=c.sock\ndata_socket=d.sock\napp_port=8080\nram_mb=768\ncpus=4\n"
    if cap_kbps: conf += "data_rate_kbps=%d\n" % cap_kbps
    open(os.path.join(base, "nether.conf"), "w").write(conf)
    p = L(base, "boot.log"); csk = os.path.join(base, "c.sock"); dsk = os.path.join(base, "d.sock")
    out = {}
    try:
        t0 = time.time()
        while not os.path.exists(csk) and time.time() - t0 < 40: time.sleep(0.1)
        s = uc(csk)
        for _ in range(120):
            s.sendall(b"echo ready\n"); b, e = framed(s, 5)
            if b"ready" in b: break
            time.sleep(0.5)
        adv = info_rate(s)
        print("  __info__ data_rate_kbps = %s" % adv); out["adv"] = adv
        s.sendall(SRV.encode() + b"\n"); framed(s, 5)
        any("UP" in cat(s, "/tmp/up") or time.sleep(0.5) for _ in range(40))
        n0, l0 = http(dsk, "/small"); # warm the path
        # /big throughput
        nb, lb = http(dsk, "/big")
        mbps = (nb / 1e6) / lb if lb else 0
        out["big_bytes"] = nb; out["big_s"] = lb; out["big_MBps"] = mbps
        print("  /big: %d bytes in %.2fs = %.2f MB/s (expected %d MiB = %d bytes)" % (nb, lb, mbps, BIG_MIB, BIG_MIB * 1024 * 1024))
        # concurrent /small responsiveness under a big flood (aggregate cap must not starve it)
        if cap_kbps:
            done = {}
            th = threading.Thread(target=lambda: done.update(zip(("n", "l"), http(dsk, "/big")))); th.start()
            time.sleep(0.05)
            lat = []
            while th.is_alive() and len(lat) < 40:
                _, l = http(dsk, "/small"); lat.append(l); time.sleep(0.02)
            th.join()
            out["small_max"] = max(lat) if lat else 0; out["small_med"] = sorted(lat)[len(lat)//2] if lat else 0
            print("  /small under /big flood: median %.3fs max %.3fs (%d samples)" % (out["small_med"], out["small_max"], len(lat)))
        try: s.sendall(b"__shutdown__\n"); s.recv(64)
        except Exception: pass
    finally:
        try: p.terminate(); time.sleep(0.5); p.kill()
        except Exception: pass
        shutil.rmtree(WORK, ignore_errors=True)
    return out

def main():
    exp = BIG_MIB * 1024 * 1024
    unc = run(0)
    cap = run(CAP_KBPS)
    print("\n================ VERDICT ================")
    ok = True
    # 1. lossless: capped and uncapped must deliver the IDENTICAL byte count (the ~38 extra over
    #    the raw body is the HTTP header), and it must cover the full 8 MiB body.
    ub, cb = unc.get("big_bytes"), cap.get("big_bytes")
    if ub == cb and ub is not None and ub >= exp:
        print("OK: lossless - capped and uncapped both deliver %d bytes (>= %d body)" % (ub, exp))
    else:
        print("FAIL: capped delivered %s bytes vs uncapped %s (>= %d body) - pacing dropped/added bytes" % (cb, ub, exp)); ok = False
    # 2. advertised
    if cap.get("adv") != CAP_KBPS:
        print("FAIL: __info__ data_rate_kbps=%s, expected %d" % (cap.get("adv"), CAP_KBPS)); ok = False
    else:
        print("OK: __info__ advertises data_rate_kbps=%d" % CAP_KBPS)
    if unc.get("adv") != 0:
        print("FAIL: uncapped __info__ data_rate_kbps=%s, expected 0" % unc.get("adv")); ok = False
    # 3. capped throughput lands near the cap (tolerance for the 200ms burst + window prefill)
    cm = cap.get("big_MBps", 0); um = unc.get("big_MBps", 0)
    lo, hi = CAP_MBps * 0.75, CAP_MBps * 1.5
    if lo <= cm <= hi:
        print("OK: capped /big = %.2f MB/s, within [%.2f, %.2f] of the %.2f MB/s cap" % (cm, lo, hi, CAP_MBps))
    else:
        print("FAIL: capped /big = %.2f MB/s, outside [%.2f, %.2f] of the %.2f MB/s cap" % (cm, lo, hi, CAP_MBps)); ok = False
    # 4. cap is a real throttle: capped << uncapped
    if um > cm * 3:
        print("OK: uncapped /big = %.2f MB/s >> capped %.2f MB/s (%.1fx) - the cap is a real throttle" % (um, cm, um / cm if cm else 0))
    else:
        print("FAIL: uncapped /big = %.2f MB/s not clearly faster than capped %.2f MB/s" % (um, cm)); ok = False
    # 5. the cap is a per-VM AGGREGATE: /small shares the same bucket as the flooding /big, so it
    #    is paced too (correct - the VM's TOTAL is capped), but must still COMPLETE, not starve.
    sm = cap.get("small_max", 99); smed = cap.get("small_med", 99)
    if sm < 3.0:
        print("OK: /small completes under the flood (median %.3fs max %.3fs) - shares the aggregate cap, not starved" % (smed, sm))
    else:
        print("FAIL: /small max %.3fs - a concurrent conn is starved, not just paced" % sm); ok = False
    print("\n%s" % ("VERDICT: PASS - data_rate_kbps paces a flooding tenant to the cap, advertised, lossless." if ok
                     else "VERDICT: FAIL - see above."))
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
