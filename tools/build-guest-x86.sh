#!/usr/bin/env bash
# Build the x86_64 guest image for the KVM/x86 platform path: a busybox initramfs
# with the static agent, TCP/vsock forwarder and loopback networking. Use
# --runtimes for an Alpine image with Python/SQLite/Node (requires Docker). The
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
OUT="${OUT:-kernels}"
MODE="${1:---minimal}"
case "$MODE" in
  --minimal|--runtimes) ;;
  *) echo "usage: $0 [--minimal|--runtimes] (OUT=directory, RUNTIMES='python3 sqlite nodejs e2fsprogs')" >&2; exit 1 ;;
esac
if [ "$MODE" = --runtimes ]; then
  command -v docker >/dev/null || { echo "error: --runtimes requires Docker" >&2; exit 1; }
fi
BB_URL="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
# The mountpoint dirs MUST exist in the initramfs or the init's mounts silently fail
# (busybox `mount` does not create the target). Without /sys the init can't even find
# the NIC (`ls /sys/class/net`), so networking never comes up - the KVM "no eth" symptom.
mkdir -p "$ROOT"/{bin,proc,sys,dev,etc,tmp,var/tmp} "$OUT"

if [ "$MODE" = --minimal ]; then
  if [ -n "${BUSYBOX_X86:-}" ]; then
    cp "$BUSYBOX_X86" "$ROOT/bin/busybox"
  else
    echo "[guest-x86] fetching static busybox"
    curl -fSL --connect-timeout 15 --max-time 120 "$BB_URL" -o "$ROOT/bin/busybox"
  fi
  chmod +x "$ROOT/bin/busybox"
fi

echo "[guest-x86] cross-compiling agent, vsock client and forwarder (x86_64-linux-musl)"
"$ZIG" cc -target x86_64-linux-musl -static -O2 tools/agent.c        -o "$ROOT/agent"
"$ZIG" cc -target x86_64-linux-musl -static -O2 tools/vsock_client.c -o "$ROOT/vsock_client"
"$ZIG" cc -target x86_64-linux-musl -static -O2 tools/forwarder.c    -o "$ROOT/forwarder"

echo "[guest-x86] writing /init"
cat > "$ROOT/init" <<'SH'
#!/bin/busybox sh
/bin/busybox --install -s /bin
mkdir -p /proc /sys /dev /etc /tmp
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sys /sys 2>/dev/null
mount -t devtmpfs dev /dev 2>/dev/null
chmod 1777 /tmp /var/tmp
# Both inbound app traffic and outbound egress use loopback, even with net=0.
ip link set lo up
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
if grep -qE 'nether\.(app_port|egress_port)=' /proc/cmdline; then
  /forwarder &
fi
# The serial console stays an interactive shell (the host drives stdin into ttyS0).
exec /bin/sh
SH
chmod +x "$ROOT/init"

echo "[guest-x86] packing initramfs"
if [ "$MODE" = --runtimes ]; then
  read -r -a PACKAGES <<< "${RUNTIMES:-python3 sqlite nodejs e2fsprogs}"
  docker run --rm --platform linux/amd64 -v "$ROOT:/build:ro" \
    -v "$(cd "$OUT" && pwd -P):/out" alpine:3.21 sh -ec '
      mkdir -p /rootfs/etc/apk
      cp -a /etc/apk/. /rootfs/etc/apk/
      apk --root /rootfs --initdb --no-cache add alpine-baselayout busybox musl "$@"
      cp -a /build/. /rootfs/
      echo "nether:x:1000:1000:nether:/home/nether:/bin/sh" >> /rootfs/etc/passwd
      echo "nether:x:1000:" >> /rootfs/etc/group
      mkdir -p /rootfs/home/nether
      chown 1000:1000 /rootfs/home/nether
      chmod 1777 /rootfs/tmp /rootfs/var/tmp
      cd /rootfs
      find . | cpio -o -H newc > /tmp/guest.cpio
      gzip -9 < /tmp/guest.cpio > /out/initramfs-x86.new.cpio.gz
    ' sh "${PACKAGES[@]}"
else
  ( cd "$ROOT" && find . | cpio -o -H newc --quiet | gzip -9 ) > "$OUT/initramfs-x86.new.cpio.gz"
fi
mv "$OUT/initramfs-x86.new.cpio.gz" "$OUT/initramfs-x86.cpio.gz"
echo "[guest-x86] wrote $OUT/initramfs-x86.cpio.gz ($(du -h "$OUT/initramfs-x86.cpio.gz" | cut -f1))"
echo "[guest-x86] kernel: build a CONFIG_PVH vmlinux per docs/running-on-kvm.md and"
echo "[guest-x86] copy it to ./vmlinux; copy this initramfs to ./initramfs; then run."
