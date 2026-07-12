#!/usr/bin/env bash
#
# sign.sh - codesign the nether binary with the hypervisor entitlement, safely.
#
# This is the single source of truth for signing. build.zig, the e2e harness, and
# CI all call it, so the four hard-won gotchas in docs/codesigning.md are enforced
# in exactly one place. It is idempotent (re-signing is fine) and exits non-zero on
# any failure, so a harness can gate a launch on it.
#
# Usage:
#   scripts/sign.sh [BINARY] [ENTITLEMENTS]     sign then verify (default action)
#   scripts/sign.sh --verify [BINARY]           verify only, do NOT (re)sign
#   scripts/sign.sh --help
#
#   BINARY        defaults to zig-out/bin/nether
#   ENTITLEMENTS  defaults to nether.entitlements
#
# Environment overrides (used by the distribution-signing spike, Workstream C):
#   SIGN_IDENTITY   codesign identity, default "-" (ad-hoc; enough for local HVF)
#   SIGN_EXTRA      extra codesign flags, e.g. "--options runtime --timestamp"
#
# Ad-hoc signing is sufficient for local dev and CI: the kernel checks the
# entitlement, not the signing identity. Developer ID / notarization is a separate
# concern (see docs/codesigning.md, distribution section).

set -euo pipefail

ENTITLEMENT_KEY="com.apple.security.hypervisor"

die() { echo "sign.sh: $*" >&2; exit 1; }

usage() {
  sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# --- assert the binary is a Mach-O arm64 (gotcha #1) ---------------------------
# codesign silently signs a non-Mach-O (an ELF, a stale x86 cross-build) as a
# "generic" file with NO entitlement slot and still exits 0. The failure only
# surfaces at runtime as HV_DENIED. Refuse anything that is not Mach-O arm64.
assert_macho_arm64() {
  local bin="$1"
  [ -f "$bin" ] || die "no such binary: $bin"
  local desc
  desc="$(file -b "$bin")"
  case "$desc" in
    *Mach-O*arm64*) : ;;
    *) die "refusing to sign non-(Mach-O arm64) binary: $bin
       file says: $desc
       (an ELF/x86 build signs 'generic', drops the entitlement, and only fails at runtime as HV_DENIED;
        build the native binary with:  ~/Library/zig/0.16.0/zig build -Dtarget=native)" ;;
  esac
}

# --- verify the hypervisor entitlement is actually embedded (gotcha #4) --------
# macOS 26 changed the -d readback: the ':-' form is the reliable one; the older
# '--entitlements -' can print nothing even when correct. Try both, then fall
# back to the code-directory slot count as a last resort.
verify_entitlement() {
  local bin="$1"
  # Signature must be structurally valid first.
  codesign --verify --strict "$bin" 2>/dev/null || die "codesign --verify failed on $bin (not signed, or signature broken)"
  if codesign -d --entitlements :- "$bin" 2>/dev/null | grep -aq "$ENTITLEMENT_KEY"; then
    return 0
  fi
  if codesign -d --entitlements - "$bin" 2>/dev/null | grep -aq "$ENTITLEMENT_KEY"; then
    return 0
  fi
  # Last resort: a correctly entitled Mach-O carries the entitlement special slot.
  # A mis-signed generic binary shows "Page size=none" and few/no special slots.
  if codesign -d -vvvv "$bin" 2>&1 | grep -aq "Page size=16384"; then
    # Page size is right (real Mach-O signature) but the entitlement grep failed:
    # treat as missing rather than guess.
    die "signature present on $bin but the $ENTITLEMENT_KEY entitlement is not embedded"
  fi
  die "no valid Mach-O code signature with $ENTITLEMENT_KEY on $bin"
}

# --- sign ---------------------------------------------------------------------
do_sign() {
  local bin="$1" ents="$2"
  [ -f "$ents" ] || die "no such entitlements file: $ents"
  assert_macho_arm64 "$bin"
  local identity="${SIGN_IDENTITY:--}"
  # word-split SIGN_EXTRA intentionally so callers can pass multiple flags.
  # shellcheck disable=SC2086
  codesign --sign "$identity" --entitlements "$ents" --force ${SIGN_EXTRA:-} "$bin" \
    || die "codesign failed on $bin"
  verify_entitlement "$bin"
  echo "sign.sh: OK  $bin  ($ENTITLEMENT_KEY embedded, identity='${identity}')"
}

# --- arg parse ----------------------------------------------------------------
action="sign"
case "${1:-}" in
  --help|-h) usage 0 ;;
  --verify) action="verify"; shift ;;
esac

BIN="${1:-zig-out/bin/nether}"
ENTS="${2:-nether.entitlements}"

case "$action" in
  verify)
    assert_macho_arm64 "$BIN"
    verify_entitlement "$BIN"
    echo "sign.sh: OK  $BIN  is signed with $ENTITLEMENT_KEY"
    ;;
  sign)
    do_sign "$BIN" "$ENTS"
    ;;
esac
