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

# Default set: the python / SQLite / JS runtimes, plus e2fsprogs so a workload can
# mkfs.ext4 a persistent disk (disk=<path>) in-guest. Override via the RUNTIMES env.
RUNTIMES="${RUNTIMES:-python3 sqlite nodejs e2fsprogs}"

[ -d kernels/rootfs ] || {
  echo "error: kernels/rootfs/ missing -- build the base rootfs first (docs/running-on-hvf.md)" >&2
  exit 1
}
command -v docker >/dev/null || { echo "error: docker not found" >&2; exit 1; }

# Write the canonical /init (the tracked source of the guest boot logic): load the
# virtio/vsock/blk + ext4 modules, auto-mount a persistent disk at /data, bring up the
# slirp network, and start the agent. Regenerated here so it lives in version control
# (kernels/rootfs/ itself is a gitignored build asset).
cat > kernels/rootfs/init <<'INIT'
#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs dev /dev 2>/dev/null

# virtio-net + the vsock transport (the agent's spine); virtio-blk + ext4 for a
# persistent disk. Core virtio/virtio_pci/virtio_ring are built into the kernel.
modprobe virtio_net 2>/dev/null
modprobe vmw_vsock_virtio_transport 2>/dev/null
modprobe virtio_blk 2>/dev/null
modprobe ext4 2>/dev/null

# Persistent disk: when the host set disk=<path>, /dev/vda is a host-file-backed disk;
# auto-mount it at /data if it carries a filesystem (mkfs.ext4 it once). Harmless if raw.
if [ -b /dev/vda ]; then
	mkdir -p /data
	mount /dev/vda /data 2>/dev/null && echo "[init] persistent disk mounted at /data"
fi

# Static slirp address plan (guest 10.0.2.15, gw 10.0.2.2, DNS 10.0.2.3); slirp also
# answers DHCP if preferred.
for d in /sys/class/net/*; do
	n=${d##*/}
	[ "$n" = lo ] && continue
	ip addr add 10.0.2.15/24 dev "$n" 2>/dev/null
	ip link set "$n" up 2>/dev/null
	ip route add default via 10.0.2.2 2>/dev/null
done
ip link set lo up 2>/dev/null
echo "nameserver 10.0.2.3" > /etc/resolv.conf

# The persistent guest agent (exec-over-vsock). Exits harmlessly if the host is not in
# agent/control mode.
[ -x /agent ] && /agent &

echo
echo "  Nether - aarch64 Linux on Apple Hypervisor.framework"
echo "  $(uname -srm)"
echo
exec /bin/sh
INIT
chmod +x kernels/rootfs/init

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
