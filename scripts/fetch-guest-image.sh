#!/bin/sh
# fetch-guest-image.sh - build a bootable aarch64 Linux guest for nether (Apple Silicon / HVF).
#
# A fresh clone has no guest kernel (kernels/ is gitignored). This script produces:
#   kernels/Image                 raw arm64 kernel (unwrapped from Alpine's EFI-zboot vmlinuz)
#   kernels/initramfs.cpio.gz     Alpine aarch64 minirootfs + kernel modules + a bring-up /init
#                                 (+ the guest agent and vsock test client, if `zig` is present)
# so that `./zig-out/bin/nether` boots straight to a shell, and agent/vsock/net work.
#
# REPRODUCIBLE BY DEFAULT: the kernel + minirootfs are PINNED to an exact version AND verified
# by SHA256, so every run produces a byte-identical guest and a tampered/substituted download
# fails closed. This is the image the project is tested against.
#
#   --latest   Opt into fetching the newest kernel/minirootfs from the mirror instead of the
#              pins. UNVERIFIED and NON-reproducible - use only to test a newer Alpine before
#              bumping the pins below.
#   --force    Rebuild even if kernels/Image already exists.
#
# Requires: curl, tar, gunzip, cpio, gzip, od, shasum (all standard on macOS). `zig` (0.16.0)
# is optional - without it the kernel + rootfs + modules are still built, just no agent binaries.
#
# To move to a newer kernel: run with --latest, confirm it boots, then update the four PIN_*
# values below (the script prints the SHA256 of whatever it fetched).
set -eu

ALPINE_BRANCH="v3.21"
MIRROR="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}"

# --- PINS (reproducible default) -------------------------------------------------------------
# Exact versions + SHA256. Bump together when moving to a newer kernel (see --latest above).
PIN_KVER="6.12.95-r0"                                  # linux-virt apk (kernel + modules)
PIN_KSHA="86e7609c39def4175da43a14e0999829d6090f15d1cb63b7c58aad56749544b1"
PIN_ROOTFS="alpine-minirootfs-3.21.7-aarch64.tar.gz"
PIN_RSHA="d1d1a3fae5f4d6146e9742790a47fcb116199622cfb8439f218a4d5fbe5000da"

latest() { curl -fsSL "$1" 2>/dev/null | grep -oE "$2" | sort | tail -1; }

# Resolve repo root from this script's location, so it works from any cwd.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="${NETHER_KERNELS:-$ROOT/kernels}"   # where nether looks for the guest image
IMG="$OUT/Image"
INITRAMFS="$OUT/initramfs.cpio.gz"

force=0
use_latest=0
for a in "$@"; do
  case "$a" in
    --force) force=1 ;;
    --latest) use_latest=1 ;;
    *) echo "unknown arg: $a (use --force / --latest)" >&2; exit 2 ;;
  esac
done

if [ -f "$IMG" ] && [ -f "$INITRAMFS" ] && [ "$force" -eq 0 ]; then
  echo "guest image already present:"
  echo "  $IMG"
  echo "  $INITRAMFS"
  echo "(pass --force to rebuild)"
  exit 0
fi

for tool in curl tar gunzip cpio gzip od shasum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' not found on PATH" >&2; exit 1; }
done

# Resolve the versions to use: pinned (default) or the mirror's latest (--latest opt-in).
if [ "$use_latest" -eq 1 ]; then
  KVER=$(latest "${MIRROR}/main/aarch64/" 'linux-virt-[0-9][^"<]*\.apk' | sed -E 's/^linux-virt-(.*)\.apk$/\1/')
  ROOTFS=$(latest "${MIRROR}/releases/aarch64/" 'alpine-minirootfs-[0-9][^"<]*-aarch64\.tar\.gz')
  [ -n "$KVER" ] && [ -n "$ROOTFS" ] || { echo "error: --latest discovery failed (mirror down?)" >&2; exit 1; }
  KSHA="" ; RSHA=""   # unverified
  echo "WARNING: --latest fetches UNVERIFIED, non-reproducible images (linux-virt $KVER, $ROOTFS)."
else
  KVER="$PIN_KVER" ; KSHA="$PIN_KSHA" ; ROOTFS="$PIN_ROOTFS" ; RSHA="$PIN_RSHA"
fi

# fetch $1 -> $2, then (if $3 non-empty) verify its SHA256 == $3, failing closed with guidance.
fetch_verify() {
  url="$1"; dst="$2"; want="$3"
  if ! curl -fSL -o "$dst" "$url"; then
    echo "error: fetch failed for $url" >&2
    echo "       Alpine may have pruned this version from the branch. Run with --latest to test a" >&2
    echo "       newer image, then update the PIN_* values in this script." >&2
    exit 1
  fi
  [ -n "$want" ] || { echo "      sha256($(basename "$dst")) = $(shasum -a 256 "$dst" | cut -d' ' -f1)  [unverified --latest]"; return; }
  got=$(shasum -a 256 "$dst" | cut -d' ' -f1)
  if [ "$got" != "$want" ]; then
    echo "error: SHA256 mismatch for $(basename "$dst")" >&2
    echo "       expected $want" >&2
    echo "       got      $got" >&2
    echo "       The mirror content changed or the download was tampered with. If Alpine legitimately" >&2
    echo "       re-rolled this version, verify the new artifact and update PIN_* in this script." >&2
    exit 1
  fi
}

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
fetch_verify "${MIRROR}/main/aarch64/linux-virt-${KVER}.apk" linux-virt.apk "$KSHA"
mkdir -p lv && tar -xzf linux-virt.apk -C lv 2>/dev/null || true
[ -f lv/boot/vmlinuz-virt ] || { echo "error: vmlinuz-virt not in the apk - bump the pin" >&2; exit 1; }
unwrap_zboot lv/boot/vmlinuz-virt "$IMG"
echo "      -> $IMG ($(wc -c < "$IMG") bytes)"

echo "[2/4] fetching minirootfs (${ROOTFS})..."
fetch_verify "${MIRROR}/releases/aarch64/${ROOTFS}" minirootfs.tar.gz "$RSHA"
mkdir -p rootfs && tar -xzf minirootfs.tar.gz -C rootfs

echo "[3/4] installing modules + bring-up /init..."
KMODVER=$(ls lv/lib/modules 2>/dev/null | head -1)
[ -n "$KMODVER" ] || { echo "error: no modules dir in the apk" >&2; exit 1; }
rm -rf rootfs/lib/modules && mkdir -p rootfs/lib/modules
cp -R "lv/lib/modules/${KMODVER}" rootfs/lib/modules/

cat > rootfs/init <<'INIT'
#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs dev /dev 2>/dev/null
modprobe virtio_net 2>/dev/null
modprobe vmw_vsock_virtio_transport 2>/dev/null
IFACE=$(ls /sys/class/net 2>/dev/null | grep -v '^lo$' | head -n1)
if [ -n "$IFACE" ]; then
  ip addr add 10.0.2.15/24 dev "$IFACE" 2>/dev/null
  ip link set "$IFACE" up 2>/dev/null
  ip route add default via 10.0.2.2 2>/dev/null
  echo "nameserver 10.0.2.3" > /etc/resolv.conf 2>/dev/null
fi
echo; echo "  Nether - aarch64 Linux on Apple Hypervisor.framework"
echo "  $(uname -srm)"; echo
[ -x /agent ] && /agent
exec /bin/sh
INIT
chmod +x rootfs/init

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
echo "done (reproducible pin: linux-virt ${KVER}, ${ROOTFS}). Build, sign, and boot:"
echo "  zig build -Dtarget=native"
echo "  codesign --sign - --entitlements nether.entitlements --force zig-out/bin/nether"
echo "  ./zig-out/bin/nether"
