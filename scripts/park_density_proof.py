#!/usr/bin/env python3
# Park density proof: a PARKED FLEET, measured. Bake one base; fork N VMs from it; drive
# each to an in-flight upstream request; __park__ each (fork re-park at fleet scale). While
# parked the fleet is NOTHING but files - zero processes, zero RAM, zero CPU. Then wake
# each and measure restore -> reply-delivered latency (each guest's blocked recv() must
# complete with ITS OWN VM's reply - park files must not cross-wire).
#
# This is the product story with numbers: N agents mid-await cost only disk; any one of
# them is ~a-tenth-of-a-second from continuing exactly where it slept.
import os, socket, subprocess, sys, time, threading, shutil, glob

NB = os.environ.get("NETHER_ROOT") or os.path.expanduser("~/nether"); BIN = NB + "/zig-out/bin/nether"
WORK = os.environ.get("NETHER_WORK", "/tmp/npkd"); RS = 0x1e
N = 10  # fleet size (each park file ~ram_mb, so N*512MB transient disk)

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

def wait_sock(p, to=40):
    t0 = time.time()
    while not os.path.exists(p):
        if time.time() - t0 > to: return False
        time.sleep(0.0003)
    return True

class Broker:
    """Per-VM upstream proxy (production shape: one egress_socket per VM). Parks the
    fresh conn's request; replies REPLY-FOR-<tag> on the resume dial."""
    def __init__(self, path, tag):
        self.tag = tag; self.parked = threading.Event(); self.resumed = threading.Event()
        self.errors = []
        if os.path.exists(path): os.unlink(path)
        self.ls = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.ls.bind(path); self.ls.listen(8)
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
            res = "resume=1" in pre
            if res:
                self.resumed.set()
                c.sendall(("REPLY-FOR-%s\n" % self.tag).encode())
                try: c.recv(4096)
                except Exception: pass
                c.close(); return
            c.settimeout(10)
            req = c.recv(4096)
            if self.tag.encode() not in req:
                self.errors.append("%s: wrong tag in request %r" % (self.tag, req)); c.close(); return
            self.parked.set()
            try: c.recv(4096)  # hold until the VM parks/dies
            except Exception: pass
        except Exception as ex:
            self.errors.append("%s: %r" % (self.tag, ex))

def slow_req(tag):
    return ("python3 -c \"import socket;s=socket.create_connection(('127.0.0.1',9090));"
            "s.sendall(b'GET /%s\\n');d=s.recv(65536);open('/tmp/reply','wb').write(d);print('done')\""
            " >/tmp/req.log 2>&1 &") % tag

def pct(xs, p):
    xs = sorted(xs); return xs[min(len(xs) - 1, int(round(p / 100.0 * (len(xs) - 1))))]

def main():
    if not os.path.exists(BIN): print("FAIL: build %s first" % BIN); return 1
    shutil.rmtree(WORK, ignore_errors=True); os.makedirs(WORK)
    base = os.path.join(WORK, "base"); os.makedirs(base)
    os.symlink(NB + "/kernels", os.path.join(base, "kernels"))
    # The base's own egress socket is a placeholder broker (no requests from the base);
    # what matters is nether.egress_port on the cmdline, which every fork INHERITS.
    Broker(os.path.join(WORK, "e-base.sock"), "base")
    open(os.path.join(base, "nether.conf"), "w").write(
        "control_socket=c.sock\negress_socket=%s\negress_port=9090\nram_mb=512\ncpus=2\n"
        % os.path.join(WORK, "e-base.sock"))
    fails = []; procs = []
    try:
        # 1. Bake the base once (kind=base: durable, forks many).
        bp = launch(base, "boot.log"); procs.append(bp)
        csk = os.path.join(base, "c.sock")
        if not wait_sock(csk): print("FAIL: base never came up"); return 1
        s = uc(csk)
        for _ in range(120):
            if "ready" in cmd(s, "echo ready", 5): break
            time.sleep(0.5)
        rep = cmd(s, "__snapshot__ base.snap", 90)
        if "OK" not in rep: fails.append("base bake failed: %r" % rep)
        cmd(s, "__shutdown__", 5)
        bp.wait(timeout=10)
        base_snap = os.path.join(base, "base.snap")
        print("[bake] base ready (%d MiB)" % (os.path.getsize(base_snap) // (1 << 20)))

        # 2. Fleet: fork N VMs, drive each to an in-flight upstream, park each.
        brokers = {}; park_times = []
        for i in range(1, N + 1):
            tag = "vm-%02d" % i
            d = os.path.join(WORK, tag); os.makedirs(d)
            es = os.path.join(WORK, "e-%02d.sock" % i)
            brokers[tag] = Broker(es, tag)
            open(os.path.join(d, "nether.conf"), "w").write(
                "restore=1\nrestore_from=%s\ncontrol_socket=v.sock\negress_socket=%s\n" % (base_snap, es))
            t0 = time.time()
            p = launch(d, "run.log"); procs.append(p)
            vsk = os.path.join(d, "v.sock")
            if not wait_sock(vsk, 30): fails.append("%s never came up" % tag); continue
            vs = uc(vsk)
            cmd(vs, slow_req(tag), 15)
            if not brokers[tag].parked.wait(15): fails.append("%s request never reached the broker" % tag); continue
            time.sleep(0.6)  # settle into recv()/WFI
            rep = cmd(vs, "__park__ p.snap", 90)
            if not rep.startswith("OK parked"): fails.append("%s park failed: %r" % (tag, rep)); continue
            try:
                if p.wait(timeout=10) != 0: fails.append("%s park exit != 0" % tag)
            except subprocess.TimeoutExpired:
                fails.append("%s did not exit after park" % tag); p.kill(); continue
            dt = time.time() - t0
            park_times.append(dt)
            print("[fleet] %s: forked, drove, parked in %.2fs" % (tag, dt))

        # 3. The parked fleet: NOTHING but files.
        time.sleep(0.5)
        alive = subprocess.run(["pgrep", "-f", BIN], capture_output=True).stdout.decode().split()
        parks = glob.glob(os.path.join(WORK, "vm-*", "p.snap"))
        total = sum(os.path.getsize(p) for p in parks)
        print("\n[parked] fleet of %d: %d nether processes alive, %d park files, %.1f GiB disk"
              % (N, len(alive), len(parks), total / (1 << 30)))
        if alive: fails.append("%d nether processes still alive while fleet parked" % len(alive))
        if len(parks) != N: fails.append("expected %d park files, found %d" % (N, len(parks)))

        # 4. Wake each; measure restore -> reply-delivered; verify per-VM reply integrity.
        wake_lat = []
        for i in range(1, N + 1):
            tag = "vm-%02d" % i
            d = os.path.join(WORK, tag)
            w = os.path.join(WORK, "w-%02d" % i); os.makedirs(w)
            open(os.path.join(w, "nether.conf"), "w").write(
                "restore=1\nrestore_from=%s\ncontrol_socket=w.sock\negress_socket=%s\n"
                % (os.path.join(d, "p.snap"), os.path.join(WORK, "e-%02d.sock" % i)))
            t0 = time.time()
            p = launch(w, "wake.log"); procs.append(p)
            wsk = os.path.join(w, "w.sock")
            if not wait_sock(wsk, 30): fails.append("%s wake never came up" % tag); continue
            ws = uc(wsk)
            got = ""
            while time.time() - t0 < 20:
                got = cat(ws, "/tmp/reply")
                if got: break
                time.sleep(0.0003)
            dt = time.time() - t0
            want = "REPLY-FOR-%s" % tag
            if got != want:
                fails.append("%s cross-wire: got %r want %r" % (tag, got, want))
            else:
                wake_lat.append(dt)
                print("[wake ] %s: recv completed with its own reply in %.3fs" % (tag, dt))
            if os.path.exists(os.path.join(d, "p.snap")): fails.append("%s park not consumed" % tag)
            try: cmd(ws, "__shutdown__", 5)
            except Exception: pass

        for b in brokers.values(): fails.extend(b.errors)
        print("\n================ NUMBERS ================")
        if park_times:
            print("fork->drive->park cycle: p50 %.2fs  p95 %.2fs  (n=%d)" % (pct(park_times, 50), pct(park_times, 95), len(park_times)))
        print("parked fleet footprint: 0 processes, 0 RAM, 0 CPU - %.1f GiB of files (%d VMs)" % (total / (1 << 30), N))
        if wake_lat:
            print("wake (restore -> guest recv completed): p50 %.3fs  p95 %.3fs  max %.3fs  (n=%d)"
                  % (pct(wake_lat, 50), pct(wake_lat, 95), max(wake_lat), len(wake_lat)))
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
    print("RESULT: PASS - a fleet of %d agents parked mid-await as pure files (zero processes/RAM/CPU)," % N)
    print("each woken on demand with its OWN upstream reply completing the original blocking recv().")
    print("Park density is real: awaiting agents cost disk, not compute.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
