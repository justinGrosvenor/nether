#!/usr/bin/env python3
# Prove clonefile base dedup end to end: build a synthetic FULL base + a content-diff against it,
# run the nether binary's materialize path, and confirm the materialized base (a) is byte-correct
# and (b) shares its RAM blocks with the base on disk (APFS clone) rather than costing full size.
import os, struct, subprocess, sys

NB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = NB + "/zig-out/bin/nether"
WORK = "/tmp/nether-mat-proof"
os.makedirs(WORK, exist_ok=True)

MAGIC, VER = 0x4e534e50, 5
RAM_FULL, RAM_DIFF = 0, 1
HDR, PAGE = 128, 16384
MOFF = 4096                      # fake metadata region
RAM_OFF = HDR + MOFF
NPAGES = 4096                    # 4096 * 16K = 64 MiB RAM
RAM = NPAGES * PAGE

def hdr(encoding, diff_pages, base_ram):
    h = bytearray(HDR)
    struct.pack_into("<I", h, 0, MAGIC)
    struct.pack_into("<I", h, 4, VER)
    struct.pack_into("<Q", h, 24, RAM)          # ram_size
    struct.pack_into("<Q", h, 48, RAM_OFF)      # ram_off
    struct.pack_into("<I", h, 84, encoding)     # ram_encoding
    struct.pack_into("<I", h, 96, diff_pages)   # diff_pages
    struct.pack_into("<Q", h, 100, base_ram)    # base_ram_size
    return bytes(h)

base_p = WORK + "/base.snap"
diff_p = WORK + "/child.diff"
out_p  = WORK + "/child.snap"
for p in (out_p,):
    if os.path.exists(p): os.remove(p)

# base: FULL, metadata=0xBB, RAM = per-page byte (page k -> k & 0xff)
base_ram = bytearray(RAM)
for k in range(NPAGES):
    base_ram[k*PAGE:(k+1)*PAGE] = bytes([k & 0xff]) * PAGE
with open(base_p, "wb") as f:
    f.write(hdr(RAM_FULL, 0, 0)); f.write(b"\xBB"*MOFF); f.write(base_ram)

# diff: DIFF vs base, metadata=0xCC, only 3 pages diverge (0, 100, NPAGES-1)
changed = {0: 0xA1, 100: 0xA2, NPAGES-1: 0xA3}
with open(diff_p, "wb") as f:
    f.write(hdr(RAM_DIFF, len(changed), RAM)); f.write(b"\xCC"*MOFF)
    for idx, val in changed.items():
        f.write(struct.pack("<I", idx)); f.write(bytes([val])*PAGE)

# run: nether reads materialize_* from nether.conf, does the clone+overlay, exits.
conf = WORK + "/nether.conf"
with open(conf, "w") as f:
    f.write("materialize_out=%s\nmaterialize_base=%s\nmaterialize_diff=%s\n" % (out_p, base_p, diff_p))

def free_bytes():
    s = os.statvfs(WORK); return s.f_bavail * s.f_frsize

# Volume free-space delta is the honest dedup measure: `du` counts allocated blocks per inode
# and does NOT reflect APFS clone sharing (both files refcount the shared blocks). A full copy
# consumes ~64 MiB of free space; a clone consumes only the diverged blocks.
before = free_bytes()
r = subprocess.run([BIN], cwd=WORK, capture_output=True, text=True, timeout=30)
consumed = before - free_bytes()
if r.returncode != 0:
    print("materialize FAILED rc=%d\n%s\n%s" % (r.returncode, r.stdout, r.stderr)); sys.exit(1)

# verify byte-correctness: out = child metadata + base RAM with the 3 pages overlaid, FULL header
with open(out_p, "rb") as f: out = f.read()
enc, = struct.unpack_from("<I", out, 84)
dp,  = struct.unpack_from("<I", out, 96)
brs, = struct.unpack_from("<Q", out, 100)
assert enc == RAM_FULL and dp == 0 and brs == 0, ("header not FULL", enc, dp, brs)
assert out[HDR:RAM_OFF] == b"\xCC"*MOFF, "child metadata not spliced"
want = bytearray(base_ram)
for idx, val in changed.items():
    want[idx*PAGE:(idx+1)*PAGE] = bytes([val])*PAGE
assert out[RAM_OFF:RAM_OFF+RAM] == bytes(want), "RAM overlay mismatch"

# dedup verdict from the free-space delta.
logical_mib = (RAM_OFF+RAM)/(1024*1024)
full_copy = RAM_OFF + RAM
print("byte-correct: FULL header, child metadata, 3 pages overlaid onto 64 MiB base RAM  OK")
print("logical size of the materialized base: ~%.0f MiB" % logical_mib)
print("free space consumed by materialize:    %d KiB" % (consumed//1024))
print("a full byte copy would have consumed:   ~%d KiB" % (full_copy//1024))
shared = consumed < full_copy // 4    # a clone costs the ~48 KiB of diverged blocks, not 64 MiB
print("DEDUP %s: the clone consumed %.2f%% of a full copy (RAM blocks shared with the base)" %
      ("CONFIRMED" if shared else "NOT observed", 100.0*consumed/full_copy))
sys.exit(0 if shared else 2)
