#!/usr/bin/env bash
# Build the x86_64 guest image for the KVM/x86 platform path: a busybox initramfs
# with the static agent + an /init that brings up vsock/net and starts it. The
# x86 analog of the aarch64 recipe in docs/running-on-hvf.md, so a Linux/KVM
# sandbox boots straight into the agent platform (control socket, agent,
# metering, render) the same as the HVF path.
#
# The CONFIG_PVH `vmlinux` is built separately on a Linux host (see
# docs/running-on-kvm.md); it must enable the platform stack (=y so no modprobe):
#   VIRTIO_PCI VIRTIO_BLK VIRTIO_NET VIRTIO_CONSOLE VSOCK VIRTIO_VSOCKETS
#
# Output: kernels/initramfs-x86.cpio.gz. Run from the repo root.
# Verifiable on a Mac (cross-compiles the agent, fetches busybox, packs cpio);
# only running the result needs an x86/KVM host.
set -euo pipefail

ZIG="${ZIG:-zig}"
OUT=kernels
BB_URL="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
# The mountpoint dirs MUST exist in the initramfs or the init's mounts silently fail
# (busybox `mount` does not create the target). Without /sys the init can't even find
# the NIC (`ls /sys/class/net`), so networking never comes up - the KVM "no eth" symptom.
mkdir -p "$ROOT"/{bin,proc,sys,dev,etc,tmp} "$OUT"

echo "[guest-x86] fetching static busybox"
curl -fSL "$BB_URL" -o "$ROOT/bin/busybox"
chmod +x "$ROOT/bin/busybox"

echo "[guest-x86] cross-compiling the agent + vsock client (x86_64-linux-musl)"
"$ZIG" cc -target x86_64-linux-musl -static -O2 tools/agent.c        -o "$ROOT/agent"
"$ZIG" cc -target x86_64-linux-musl -static -O2 tools/vsock_client.c -o "$ROOT/vsock_client"

echo "[guest-x86] writing /init"
cat > "$ROOT/init" <<'SH'
#!/bin/busybox sh
/bin/busybox --install -s /bin
mkdir -p /proc /sys /dev /etc /tmp
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sys /sys 2>/dev/null
mount -t devtmpfs dev /dev 2>/dev/null
# Net (best-effort): static config to the slirp plan; harmless if net is disabled.
IF="$(ls /sys/class/net 2>/dev/null | grep -v '^lo$' | head -n1)"
if [ -n "$IF" ]; then
  ip link set "$IF" up
  ip addr add 10.0.2.15/24 dev "$IF"
  ip route add default via 10.0.2.2
  echo "nameserver 10.0.2.3" > /etc/resolv.conf
fi
# The persistent agent connects to the host on vsock port 5000. Harmless when the
# host is not in agent/control mode (it fails to connect and exits).
/agent &
# The serial console stays an interactive shell (the host drives stdin into ttyS0).
exec /bin/sh
SH
chmod +x "$ROOT/init"

echo "[guest-x86] packing initramfs"
( cd "$ROOT" && find . | cpio -o -H newc --quiet | gzip -9 ) > "$OUT/initramfs-x86.cpio.gz"
echo "[guest-x86] wrote $OUT/initramfs-x86.cpio.gz ($(du -h "$OUT/initramfs-x86.cpio.gz" | cut -f1))"
echo "[guest-x86] kernel: build a CONFIG_PVH vmlinux per docs/running-on-kvm.md and"
echo "[guest-x86] copy it to ./vmlinux; copy this initramfs to ./initramfs; then run."
