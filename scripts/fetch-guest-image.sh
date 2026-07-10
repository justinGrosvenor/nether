#!/bin/sh
# fetch-guest-image.sh - build a bootable aarch64 Linux guest for nether (Apple Silicon / HVF).
#
# A fresh clone has no guest kernel (kernels/ is gitignored). This script produces:
#   kernels/Image                 raw arm64 kernel (unwrapped from Alpine's EFI-zboot vmlinuz)
#   kernels/initramfs.cpio.gz     Alpine aarch64 minirootfs + kernel modules + a bring-up /init
#                                 (+ the guest agent and vsock test client, if `zig` is present)
# so that `./zig-out/bin/nether` boots straight to a shell, and agent/vsock/net work.
#
# Idempotent: re-running rebuilds from scratch under a temp dir. Pass --force to refetch even
# if kernels/Image already exists.
#
# Requires: curl, tar, gunzip, cpio, gzip, od (all standard on macOS). `zig` (0.16.0) is
# optional - without it the kernel + rootfs + modules are still built, just no agent binaries.
#
# The Alpine BRANCH is pinned; the kernel + minirootfs versions are auto-discovered from the
# mirror (Alpine bumps the kernel within a stable branch, so pinning a patch version rots).
# The pins below are only fallbacks if discovery fails. To move to a newer Alpine, bump
# ALPINE_BRANCH to a current release under https://dl-cdn.alpinelinux.org/alpine/ and re-run.
set -eu

ALPINE_BRANCH="v3.21"
KVER_FALLBACK="6.12.95-r0"                                  # linux-virt apk (kernel + modules)
MINIROOTFS_FALLBACK="alpine-minirootfs-3.21.7-aarch64.tar.gz"
MIRROR="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}"

# newest matching filename from a mirror directory listing (plain sort: patch versions within
# a branch are same-width, so lexical order is correct). $1 = URL dir, $2 = grep pattern.
latest() { curl -fsSL "$1" 2>/dev/null | grep -oE "$2" | sort | tail -1; }

KVER=$(latest "${MIRROR}/main/aarch64/" 'linux-virt-[0-9][^"<]*\.apk' | sed -E 's/^linux-virt-(.*)\.apk$/\1/')
[ -n "$KVER" ] || KVER="$KVER_FALLBACK"
MINIROOTFS=$(latest "${MIRROR}/releases/aarch64/" 'alpine-minirootfs-[0-9][^"<]*-aarch64\.tar\.gz')
[ -n "$MINIROOTFS" ] || MINIROOTFS="$MINIROOTFS_FALLBACK"

# Resolve repo root from this script's location, so it works from any cwd.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="${NETHER_KERNELS:-$ROOT/kernels}"   # where nether looks for the guest image
IMG="$OUT/Image"
INITRAMFS="$OUT/initramfs.cpio.gz"

force=0
[ "${1:-}" = "--force" ] && force=1
if [ -f "$IMG" ] && [ -f "$INITRAMFS" ] && [ "$force" -eq 0 ]; then
  echo "guest image already present:"
  echo "  $IMG"
  echo "  $INITRAMFS"
  echo "(pass --force to rebuild)"
  exit 0
fi

for tool in curl tar gunzip cpio gzip od; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' not found on PATH" >&2; exit 1; }
done

mkdir -p "$OUT"
work=$(mktemp -d "${TMPDIR:-/tmp}/nether-guest.XXXXXX")
trap 'rm -rf "$work"' EXIT
cd "$work"

# unwrap an Alpine EFI-zboot vmlinuz ($1) to a raw kernel Image ($2).
unwrap_zboot() {
  off=$(( $(od -An -tu4 -j8  -N4 "$1") ))   # zboot payload_offset
  len=$(( $(od -An -tu4 -j12 -N4 "$1") ))   # zboot payload_size
  tail -c +$((off + 1)) "$1" | head -c "$len" | gunzip > "$2"
}

echo "[1/4] fetching kernel + modules (linux-virt ${KVER})..."
curl -fSL -o linux-virt.apk "${MIRROR}/main/aarch64/linux-virt-${KVER}.apk"
mkdir -p lv && tar -xzf linux-virt.apk -C lv 2>/dev/null || true
[ -f lv/boot/vmlinuz-virt ] || { echo "error: vmlinuz-virt not in the apk - bump KVER" >&2; exit 1; }
unwrap_zboot lv/boot/vmlinuz-virt "$IMG"
echo "      -> $IMG ($(wc -c < "$IMG") bytes)"

echo "[2/4] fetching minirootfs (${MINIROOTFS})..."
curl -fSL -o minirootfs.tar.gz "${MIRROR}/releases/aarch64/${MINIROOTFS}"
mkdir -p rootfs && tar -xzf minirootfs.tar.gz -C rootfs

echo "[3/4] installing modules + bring-up /init..."
# the module dir name (e.g. 6.12.95-0-virt) matches the kernel's vermagic; read it from the
# extracted apk rather than deriving it, so it always matches the Image we just unwrapped.
KMODVER=$(ls lv/lib/modules 2>/dev/null | head -1)
[ -n "$KMODVER" ] || { echo "error: no modules dir in the apk" >&2; exit 1; }
# whole modules tree (with modules.dep) so the guest can modprobe by name and resolve deps
rm -rf rootfs/lib/modules && mkdir -p rootfs/lib/modules
cp -R "lv/lib/modules/${KMODVER}" rootfs/lib/modules/

# /init: mount pseudo-fs, load virtio net + vsock, static slirp IP, start the agent if baked,
# otherwise drop to an interactive shell. Matches the documented default bring-up.
cat > rootfs/init <<'INIT'
#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs dev /dev 2>/dev/null
modprobe virtio_net 2>/dev/null
modprobe vmw_vsock_virtio_transport 2>/dev/null
# slirp default plan (host user-net): 10.0.2.15/24, gw 10.0.2.2, DNS 10.0.2.3
IFACE=$(ls /sys/class/net 2>/dev/null | grep -v '^lo$' | head -n1)
if [ -n "$IFACE" ]; then
  ip addr add 10.0.2.15/24 dev "$IFACE" 2>/dev/null
  ip link set "$IFACE" up 2>/dev/null
  ip route add default via 10.0.2.2 2>/dev/null
  echo "nameserver 10.0.2.3" > /etc/resolv.conf 2>/dev/null
fi
echo; echo "  Nether - aarch64 Linux on Apple Hypervisor.framework"
echo "  $(uname -srm)"; echo
# In control/agent mode the host listens on the agent vsock port and /agent serves it;
# with no host (a plain boot) /agent connects, fails, and exits at once. Either way, fall
# through to an interactive shell as PID 1 - never `exec` /agent, or its exit panics init.
[ -x /agent ] && /agent
exec /bin/sh
INIT
chmod +x rootfs/init

# Optional: build the static guest agent + vsock client (needs zig for cross-compile).
if command -v zig >/dev/null 2>&1; then
  echo "      building guest agent + vsock_client (zig cc)..."
  zig cc -target aarch64-linux-musl -static -O2 "$ROOT/tools/agent.c"        -o rootfs/agent
  zig cc -target aarch64-linux-musl -static -O2 "$ROOT/tools/vsock_client.c" -o rootfs/vsock_client
else
  echo "      note: 'zig' not on PATH - skipping agent/vsock_client (plain-shell boot still works)"
fi

echo "[4/4] packing initramfs..."
( cd rootfs && find . | cpio -o -H newc --quiet | gzip -9 ) > "$INITRAMFS"
echo "      -> $INITRAMFS ($(wc -c < "$INITRAMFS") bytes)"

echo
echo "done. Build, sign, and boot:"
echo "  zig build -Dtarget=native"
echo "  codesign --sign - --entitlements nether.entitlements --force zig-out/bin/nether"
echo "  ./zig-out/bin/nether"
