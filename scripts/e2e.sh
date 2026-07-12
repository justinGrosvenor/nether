#!/usr/bin/env bash
#
# e2e.sh - one command from a clean checkout to a real-HVF end-to-end gate.
#
# This is the reproducible e2e the SDKs and swerver-console migration drive against.
# Hosted CI cannot run it (GitHub's macOS runners are VMs with no nested virtualization);
# it runs on real Apple Silicon. See docs/codesigning.md (distribution/e2e section).
#
# Stages:
#   1. build native + codesign          (Workstream A; scripts/sign.sh is the source of truth)
#   2. bake a minimal forkable base      (examples/e2e-base.nether.toml)
#   3. HVF gate we OWN: fork_serve.py    (boot -> snapshot -> warm fork -> serve; authoritative)
#   4. SDK e2e drivers, both SDKs         (owned by the SDK teams; we invoke + report honestly)
#
# Exit code is tiered so a caller can tell the two failure classes apart:
#   0  all green
#   1  the gate THIS spike owns failed (build/sign/bake/fork_serve) - a real regression
#   2  owned gate green, but an SDK driver is red (integration not yet green; see findings)
#
# Env:
#   ZIG                 zig 0.16.0 (default: ~/Library/zig/0.16.0/zig, else `zig` on PATH)
#   NETHER_ROOT         nether checkout (default: this script's repo)
#   E2E_SKIP_SDK=1      run only the owned gate (stages 1-3)
#   E2E_KEEP=1          keep the scratch work dir + baked base (default: clean up)

set -uo pipefail  # NOT -e: we run several gates and want to report all of them, not abort on the first.

REPO="${NETHER_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO"

ZIG="${ZIG:-}"
if [ -z "$ZIG" ]; then
  if [ -x "$HOME/Library/zig/0.16.0/zig" ]; then ZIG="$HOME/Library/zig/0.16.0/zig"; else ZIG="zig"; fi
fi

BIN="$REPO/zig-out/bin/nether"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nether-e2e.XXXXXX")"
BASE="$WORK/e2e-base.snap"
RECIPE="examples/e2e-base.nether.toml"

owned_fail=0
sdk_fail=0

cleanup() {
  if [ "${E2E_KEEP:-0}" = "1" ]; then
    echo "[e2e] E2E_KEEP=1: left scratch at $WORK"
  else
    rm -rf "$WORK"
    # the recipe writes its base next to itself; make sure we do not leave it in the tree.
    rm -f "$REPO/examples/e2e-base.snap" "$REPO/examples/e2e-base.snap.manifest.json"
  fi
}
trap cleanup EXIT

hr()  { printf '%s\n' "------------------------------------------------------------"; }
step(){ hr; echo "[e2e] $*"; hr; }

# --- 1. build + sign -----------------------------------------------------------
step "1/4 build native + codesign  ($ZIG)"
if ! "$ZIG" build -Dtarget=native; then
  echo "[e2e] FAIL: native build failed"; owned_fail=1
fi
# The build auto-signs on native macOS; gate on the entitlement being embedded.
if [ "$owned_fail" = "0" ] && ! "$REPO/scripts/sign.sh" --verify "$BIN"; then
  echo "[e2e] FAIL: binary is not signed with the hypervisor entitlement"; owned_fail=1
fi
export NETHER_BIN="$BIN"

# --- 2. bake a minimal base ----------------------------------------------------
if [ "$owned_fail" = "0" ]; then
  step "2/4 bake a forkable base  ($RECIPE)"
  if python3 scripts/bake.py bake "$RECIPE" --force; then
    # [snapshot].out resolves next to the recipe; move it into the scratch dir.
    mv "$REPO/examples/e2e-base.snap" "$BASE" 2>/dev/null
    mv "$REPO/examples/e2e-base.snap.manifest.json" "$WORK/" 2>/dev/null
    if [ -f "$BASE" ]; then
      echo "[e2e] baked base: $BASE ($(wc -c < "$BASE") bytes)"
    else
      echo "[e2e] FAIL: bake reported success but produced no base"; owned_fail=1
    fi
  else
    echo "[e2e] FAIL: bake failed"; owned_fail=1
  fi
fi

# --- 3. authoritative HVF gate: in-repo warm-fork proof ------------------------
if [ "$owned_fail" = "0" ]; then
  step "3/4 HVF gate: warm-fork proof (scripts/fork_serve.py)"
  if python3 scripts/fork_serve.py; then
    echo "[e2e] HVF gate: PASS"
  else
    echo "[e2e] FAIL: HVF warm-fork proof failed"; owned_fail=1
  fi
fi

# --- 4. SDK e2e drivers (owned by the SDK teams) -------------------------------
run_sdk() {  # name  dir  cmd...
  local name="$1" dir="$2"; shift 2
  if [ ! -d "$dir" ]; then echo "[e2e] SKIP: $name SDK not found at $dir"; return; fi
  echo "[e2e] --- $name SDK e2e ---"
  if ( cd "$dir" && NETHER_BIN="$BIN" "$@" ); then
    echo "[e2e] $name SDK e2e: PASS"
  else
    echo "[e2e] $name SDK e2e: FAIL"; sdk_fail=1
  fi
}

if [ "$owned_fail" = "0" ] && [ "${E2E_SKIP_SDK:-0}" != "1" ]; then
  step "4/4 SDK e2e drivers (real HVF, both SDKs)"
  # Each SDK's REAL driver forks the baked base and exercises create/exec/snapshot/warm-fork.
  # These are the live-sandbox drivers, NOT the unit suites (which use fakes and would not touch
  # the HVF path), so this stage actually gates the SDK-over-nether contract.
  run_sdk python "$HOME/nether-sdk-python" python3 examples/e2e.py --base "$BASE"
  # The TS driver imports ../dist/index.js, so it needs installed deps + a build first.
  ts="$HOME/nether-sdk-typescript"
  if [ ! -d "$ts/node_modules" ]; then
    echo "[e2e] SKIP: typescript SDK deps not installed (run: cd ~/nether-sdk-typescript && npm ci)"
  elif ! ( cd "$ts" && npm run build ); then
    echo "[e2e] typescript SDK e2e: FAIL (npm run build failed)"; sdk_fail=1
  else
    run_sdk typescript "$ts" node examples/e2e.mjs --base "$BASE"
  fi
fi

# --- summary -------------------------------------------------------------------
hr
if [ "$owned_fail" != "0" ]; then
  echo "[e2e] RESULT: FAIL (owned gate: build/sign/bake/fork-serve) - exit 1"
  exit 1
fi
if [ "$sdk_fail" != "0" ]; then
  echo "[e2e] RESULT: HVF gate GREEN; one or more SDK drivers RED - exit 2"
  echo "[e2e] (the owned signed-binary + base + warm-fork path is proven; SDK integration is not yet green)"
  exit 2
fi
echo "[e2e] RESULT: PASS - signed binary, baked base, warm fork, and SDK e2e all green - exit 0"
exit 0
