#!/bin/sh
# Build a warm, self-starting Swerver guest image for Nether's HVF backend.
#
# The application comes from HttpArena's committed Swerver entry so the guest is
# the same real workload used for the public benchmark, not a demonstration stub.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SWERVER_ROOT=${SWERVER_ROOT:-"$ROOT/../swerver"}
HTTPARENA_ROOT=${HTTPARENA_ROOT:-"$ROOT/../HttpArena"}
SUPERVISOR_BIN=${NETHER_SUPERVISOR_BIN:-"$ROOT/../nether-supervisor/zig-out/bin/nether-supervisor"}
ZIG=${ZIG:-zig}
OUT=${NETHER_SWERVER_KERNELS:-"$ROOT/kernels/swerver"}
BASE_KERNELS=${NETHER_KERNELS:-"$ROOT/kernels"}

for tool in "$ZIG" git tar gzip cpio awk sed file shasum; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: '$tool' not found on PATH" >&2
    exit 1
  }
done

for repo in "$SWERVER_ROOT" "$HTTPARENA_ROOT"; do
  git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1 || {
    echo "error: not a git checkout: $repo" >&2
    exit 1
  }
done

if [ ! -f "$BASE_KERNELS/Image" ] || [ ! -f "$BASE_KERNELS/initramfs.cpio.gz" ]; then
  echo "error: base guest image is missing; run $ROOT/scripts/fetch-guest-image.sh first" >&2
  exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/nether-swerver-guest.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/swerver/httparena" "$work/arena" "$work/rootfs" "$OUT"

echo "[1/5] exporting committed Swerver and HttpArena sources..."
git -C "$SWERVER_ROOT" archive HEAD | tar -x -C "$work/swerver"
git -C "$HTTPARENA_ROOT" archive HEAD frameworks/swerver | tar -x -C "$work/arena"
cp "$work/arena/frameworks/swerver/main.zig" "$work/swerver/httparena/"
cp "$work/arena/frameworks/swerver/db_routes.zig" "$work/swerver/httparena/"
cp "$work/arena/frameworks/swerver/build.zig" "$work/swerver/httparena/"
cp "$work/arena/frameworks/swerver/build.zig.zon" "$work/swerver/httparena/"

echo "[2/5] cross-compiling the HttpArena Swerver app (aarch64 Linux, static)..."
(cd "$work/swerver/httparena" && "$ZIG" build -Dtarget=aarch64-linux-musl)
guest_bin="$work/swerver/httparena/zig-out/bin/swerver-httparena"
file "$guest_bin" | grep -q 'ARM aarch64' || {
  echo "error: guest binary is not aarch64: $(file "$guest_bin")" >&2
  exit 1
}

echo "[3/5] installing Swerver into the pinned base initramfs..."
gzip -dc "$BASE_KERNELS/initramfs.cpio.gz" | (cd "$work/rootfs" && cpio -idm --quiet)
cp "$guest_bin" "$work/rootfs/swerver"
cp "$ROOT/examples/swerver-guest/guest.json" "$work/rootfs/swerver.json"
chmod 755 "$work/rootfs/swerver"

awk '
  BEGIN { inserted = 0 }
  /^exec \/bin\/sh$/ && inserted == 0 {
    print ""
    print "# Start the warm application before Nether snapshots this guest."
    print "[ -x /swerver ] && /swerver --config /swerver.json >/dev/console 2>&1 &"
    inserted = 1
  }
  { print }
  END { if (inserted == 0) exit 42 }
' "$work/rootfs/init" > "$work/rootfs/init.swerver" || {
  echo "error: could not locate the final 'exec /bin/sh' in the base /init" >&2
  exit 1
}
mv "$work/rootfs/init.swerver" "$work/rootfs/init"
chmod 755 "$work/rootfs/init"

echo "[4/5] packing the guest and building the tenant filter..."
cp "$BASE_KERNELS/Image" "$OUT/Image"
(cd "$work/rootfs" && find . -print | LC_ALL=C sort | cpio -o -H newc --quiet | gzip -9) > "$OUT/initramfs.cpio.gz"
"$ZIG" build-exe "$ROOT/examples/swerver-guest/tenant_filter.zig" \
  -target wasm32-freestanding -mcpu=mvp -fno-entry -rdynamic -OReleaseSmall \
  -femit-bin="$OUT/tenant_filter.wasm"

echo "[5/5] generating aligned gateway and supervisor configs..."
sed "s|@FILTER_WASM@|$OUT/tenant_filter.wasm|g" \
  "$ROOT/examples/swerver-guest/gateway.json.in" > "$OUT/gateway.json"
sed -e "s|@KERNELS_DIR@|$OUT|g" -e "s|@NETHER_BIN@|$ROOT/zig-out/bin/nether|g" \
  "$ROOT/examples/swerver-guest/nether-supervisor.conf.in" > "$OUT/nether-supervisor.conf"
if [ -x "$SUPERVISOR_BIN" ]; then
  cp "$SUPERVISOR_BIN" "$OUT/nether-supervisor"
  chmod 755 "$OUT/nether-supervisor"
else
  echo "note: private supervisor binary not found at $SUPERVISOR_BIN" >&2
  echo "      build it and rerun, or set NETHER_SUPERVISOR_BIN" >&2
fi

swerver_commit=$(git -C "$SWERVER_ROOT" rev-parse HEAD)
arena_commit=$(git -C "$HTTPARENA_ROOT" rev-parse HEAD)
nether_commit=$(git -C "$ROOT" rev-parse HEAD)
{
  printf 'nether_commit=%s\n' "$nether_commit"
  printf 'swerver_commit=%s\n' "$swerver_commit"
  printf 'httparena_commit=%s\n' "$arena_commit"
  printf 'zig_version=%s\n' "$("$ZIG" version)"
  shasum -a 256 "$OUT/Image" "$OUT/initramfs.cpio.gz" "$OUT/tenant_filter.wasm"
  if [ -x "$OUT/nether-supervisor" ]; then
    shasum -a 256 "$OUT/nether-supervisor"
  fi
} > "$OUT/build-info.txt"

echo "done: $OUT"
echo "  guest:      Image + initramfs.cpio.gz"
echo "  gateway:    gateway.json + tenant_filter.wasm"
echo "  supervisor: nether-supervisor.conf"
if [ -x "$OUT/nether-supervisor" ]; then
  echo "  private bin: nether-supervisor (local, gitignored)"
fi
