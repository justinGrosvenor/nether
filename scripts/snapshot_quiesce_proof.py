import os,socket,subprocess,time,shutil
NB=os.path.expanduser("~/nether");BIN=NB+"/zig-out/bin/nether";WORK="/tmp/nsnap";RS=0x1e
def uc(p,to=15):
    s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.settimeout(to);s.connect(p);return s
def un(b):
    o=bytearray();e=False
    for x in b:
        if e:o.append(x^0x40);e=False
        elif x==0x1f:e=True
        else:o.append(x)
    return bytes(o)
def framed(s,to=10):
    s.settimeout(to);b=b""
    while RS not in b:
        c=s.recv(4096)
        if not c:return un(b),None
        b+=c
    rs=b.index(RS)
    while b"\n" not in b[rs+1:]:b+=s.recv(64)
    return un(b[:rs]),int(b[rs+1:b.index(b"\n",rs+1)])
def meta(s,line,to=30):
    s.settimeout(to);s.sendall(line.encode()+b"\n");b=b""
    while b"\n" not in b:
        c=s.recv(256)
        if not c:break
        b+=c
    return b.decode(errors="replace").strip()
def L(cwd,log):return subprocess.Popen([BIN],cwd=cwd,stdin=subprocess.DEVNULL,stdout=open(os.path.join(cwd,log),"w"),stderr=subprocess.STDOUT)
def boot(name,extra=""):
    d=os.path.join(WORK,name);os.makedirs(d);os.symlink(NB+"/kernels",os.path.join(d,"kernels"))
    open(os.path.join(d,"nether.conf"),"w").write("control_socket=c.sock\nram_mb=512\ncpus=2\n"+extra)
    p=L(d,"boot.log");sk=os.path.join(d,"c.sock")
    t0=time.time()
    while not os.path.exists(sk) and time.time()-t0<40:time.sleep(0.1)
    s=uc(sk)
    for _ in range(120):
        s.sendall(b"echo ready\n");b,e=framed(s,5)
        if b"ready" in b:break
        time.sleep(0.5)
    return p,s
def spin(s):  # start a CPU-busy process, return its guest PID
    s.sendall(b"yes >/dev/null 2>&1 & echo $!\n");b,e=framed(s);return b.strip().decode()
shutil.rmtree(WORK,ignore_errors=True);os.makedirs(WORK);procs=[];fails=[]
try:
    p,s=boot("v1");procs.append(p)
    pid=spin(s);time.sleep(0.7)
    r1=meta(s,"__snapshot__ b1.snap")
    print("[default]    busy guest -> __snapshot__ : %r"%r1)
    if "OK" in r1: fails.append("default should FAIL-CLOSED on a busy guest, got OK")
    s.sendall(("kill %s 2>/dev/null; echo k\n"%pid).encode());framed(s);time.sleep(0.9)
    r2=meta(s,"__snapshot__ b2.snap")
    print("[default]    idle guest -> __snapshot__ : %r"%r2)
    if "OK" not in r2: fails.append("default should succeed on an idle guest, got %r"%r2)
    p2,s2=boot("v2","snapshot_allow_dirty=1\n");procs.append(p2)
    spin(s2);time.sleep(0.7)
    r3=meta(s2,"__snapshot__ b3.snap")
    print("[allow_dirty] busy guest -> __snapshot__ : %r"%r3)
    if "OK" not in r3: fails.append("allow_dirty override should capture best-effort, got %r"%r3)
finally:
    for p in procs:
        try:p.terminate()
        except:pass
    time.sleep(0.5)
    for p in procs:
        try:p.kill()
        except:pass
    shutil.rmtree(WORK,ignore_errors=True)
print()
print("RESULT: "+("FAIL - "+"; ".join(fails) if fails else "PASS - base snapshot fails closed on a non-quiescent guest; idle succeeds; snapshot_allow_dirty overrides."))
