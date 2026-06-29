#!/usr/bin/env bash
# Bake language runtimes into the aarch64 guest initramfs (the HVF path) and repack it,
# so a sandbox boots with python3/node/sqlite already present (no apk-at-runtime, which
# would need egress + a slow first run). Pair with a WARM base snapshot (drive a booted
# sandbox to a ready state, then `__snapshot__`) so every fork inherits the runtimes
# instantly -- see docs/running-on-hvf.md and docs/control-protocol.md "Baking a base".
#
# Starts from kernels/rootfs/ (the Alpine aarch64 minirootfs + matched kernel modules +
# the cross-compiled agent + /init, built per docs/running-on-hvf.md) and `apk add`s the
# runtimes INTO it via a native linux/arm64 Alpine container. On Apple Silicon Docker runs
# arm64 containers natively, so the apk + the packed cpio see the right arch and uid 0.
#
# Output: kernels/initramfs.cpio.gz (the previous one is backed up to .bak). Runtime set
# via the RUNTIMES env (default: python3 sqlite nodejs -- the set chosen for the python /
# SQLite / JS service classes). Run from the repo root. Requires Docker.
set -euo pipefail

RUNTIMES="${RUNTIMES:-python3 sqlite nodejs}"

[ -d kernels/rootfs ] || {
  echo "error: kernels/rootfs/ missing -- build the base rootfs first (docs/running-on-hvf.md)" >&2
  exit 1
}
command -v docker >/dev/null || { echo "error: docker not found" >&2; exit 1; }

echo "[guest-aarch64] baking runtimes into kernels/rootfs: $RUNTIMES"
docker run --rm --platform linux/arm64 -v "$PWD:/host" alpine:3.21 sh -c '
  set -e
  cp -a /host/kernels/rootfs /rootfs
  # The base minirootfs ships the alpine repos + signing keys, so apk resolves the
  # runtimes (and their deps: icu/libstdc++ for node, etc.) for aarch64 and installs
  # them into /rootfs. --no-cache keeps the image lean.
  apk add --root /rootfs --no-cache '"$RUNTIMES"'
  chmod +x /rootfs/init /rootfs/agent
  cd /rootfs && find . | cpio -o -H newc 2>/dev/null | gzip -9 > /host/kernels/initramfs.new.cpio.gz
'

[ -f kernels/initramfs.cpio.gz ] && mv kernels/initramfs.cpio.gz kernels/initramfs.cpio.gz.bak
mv kernels/initramfs.new.cpio.gz kernels/initramfs.cpio.gz
echo "[guest-aarch64] wrote kernels/initramfs.cpio.gz ($(du -h kernels/initramfs.cpio.gz | cut -f1)); previous -> .bak"
echo "[guest-aarch64] verify: boot a control sandbox and run 'python3 --version; node --version; sqlite3 --version'"
