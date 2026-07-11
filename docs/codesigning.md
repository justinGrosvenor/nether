# Codesigning nether for HVF (macOS / Apple Silicon)

Practical guide for anything that **builds or launches** the nether binary on macOS (e.g. a
supervisor that spawns one `nether` process per VM). On Apple Silicon, nether runs the guest
on Apple's Hypervisor.framework (HVF), and the kernel only hands out the hypervisor to a
process whose binary is **codesigned with the `com.apple.security.hypervisor` entitlement**.
An unsigned or wrong-signed binary builds and runs fine right up to the point it asks HVF to
create the VM/vCPU, then fails with a permission error (`HV_DENIED`) - so this is easy to get
wrong and only notice at runtime.

There is exactly one nether binary; every VM (fresh boot or snapshot fork) is that same
binary re-exec'd. So you sign it **once** after each build and reuse it for all VMs - forks
inherit nothing signing-related, they are just new processes of the already-signed binary.

## The short version (automated)

Signing is automated, so the common case is one command:

```sh
cd ~/nether
~/Library/zig/0.16.0/zig build -Dtarget=native    # builds AND codesigns; ready to run HVF
```

On a macOS host building a macOS target, `build.zig` runs `scripts/sign.sh` on the
installed binary as the last step, so `zig build -Dtarget=native` (and `zig build run`)
always leave a signed, entitlement-verified binary. The whole "rebuilt, forgot to
re-sign, HV_DENIED" class is gone.

- `scripts/sign.sh` is the single source of truth for signing. It enforces all four
  gotchas below (asserts Mach-O arm64, signs, reads the entitlement back macOS-26-aware),
  is idempotent, and exits non-zero on any failure.
- `scripts/sign.sh --verify` verifies without re-signing - a harness or CI gates a launch
  on it (exit 0 = signed with the hypervisor entitlement).
- `zig build sign -Dtarget=native` signs explicitly; `zig build -Dtarget=native -Dcodesign=false`
  builds unsigned (e.g. to hand signing to a downstream release pipeline);
  `-Dentitlements=<path>` overrides the plist.

Ad-hoc signing (no Developer ID) is what this does, and it is sufficient for local dev
and CI: the kernel checks the entitlement, not the signing identity. Distribution is
different (see "Distribution signing and notarization" below).

## The recipe (what the automation does under the hood)

`scripts/sign.sh` automates exactly this; the manual steps are here as the reference and
for anyone signing outside the Zig build:

```sh
cd ~/nether
ZIG="${ZIG:-zig}"      # requires Zig 0.16.0 (https://ziglang.org/download) - see "Toolchain" below

# 1. Build the NATIVE aarch64 macOS binary (NOT the default x86_64-linux target).
$ZIG build -Dtarget=native

# 2. Verify it is really a Mach-O arm64 BEFORE signing (see gotcha #1).
file zig-out/bin/nether                        # must say: Mach-O 64-bit executable arm64

# 3. Sign it ad-hoc with the hypervisor entitlement.
codesign --sign - --entitlements nether.entitlements --force zig-out/bin/nether

# 4. Verify the entitlement actually embedded (see gotcha #2).
codesign -d --entitlements :- zig-out/bin/nether 2>/dev/null | grep -aq hypervisor \
  && echo "OK: hypervisor entitlement embedded" || echo "FAIL: entitlement missing"
```

`nether.entitlements` (in the repo root) is just:

```xml
<plist version="1.0"><dict>
  <key>com.apple.security.hypervisor</key><true/>
</dict></plist>
```

Ad-hoc signing (`--sign -`, no Developer ID) is sufficient for local dev; the entitlement, not
the identity, is what HVF checks.

## Gotchas (each one has bitten us)

**1. An ELF / x86 binary signs "generic" and SILENTLY drops the entitlement.** `codesign` only
embeds entitlements into a Mach-O code signature. If `zig-out/bin/nether` is an ELF (e.g. the
default `x86_64-linux` build, or a stale one), `codesign` still exits 0 but signs it as a
generic file (`Page size=none`) with **no entitlement slot** - no error, no warning. You then
discover it at runtime as `HV_DENIED`. **Always `file` the binary first**; it must be
`Mach-O 64-bit executable arm64`. This is why step 2 exists.

**2. Build with `-Dtarget=native`, not `-Dtarget=aarch64-macos`.** nether's `build.zig` default
target is `x86_64-linux` (so it type-checks on any host), so a plain `zig build` produces a
Linux ELF. Use `-Dtarget=native` to get the native macOS Mach-O. Do **not** use
`-Dtarget=aarch64-macos` explicitly: zig treats that as a *cross* target and does not add the
macOS SDK's framework search path, so the link fails with `unable to find framework 'Hypervisor'`.
Only `native` pulls in the SDK.

**3. An x86 cross-build clobbers the native binary.** `zig build -Dtarget=x86_64-linux`
overwrites `zig-out/bin/nether` with the Linux ELF (which then "exec format error"s on macOS
and, if signed, drops the entitlement per gotcha #1). If you build both targets, **rebuild
native + re-sign as the last step** before any HVF run.

**4. macOS 26's `codesign -d` display changed.** Reading back embedded entitlements: use
`codesign -d --entitlements :- <bin>` (the `:-` form). The older `--entitlements -` may print
nothing on macOS 26 even when the entitlement is present. If the readback looks empty, confirm
via the code directory instead: `codesign -d -vvvv <bin>` on a correctly signed binary shows
`Page size=16384` and `hashes=<N>+7` (7 special slots incl. the entitlement); a mis-signed
generic binary shows `Page size=none` / few slots.

## Toolchain

Use **zig 0.16.0 stable** ([ziglang.org/download](https://ziglang.org/download)), not whatever
`zig` happens to be on `PATH`. An older `0.16.0-dev` zig (a) lacks
`std.testing.Smith` that the fuzz targets need, and (b) has a MachO linker that cannot parse the
current Xcode SDK's `libSystem.tbd` (the Xcode 26.5 SDK dropped `arm64-macos` from its
top-level `targets:`), so every `-lc` link resolves zero symbols
(`undefined symbol: _malloc`, ...). The 0.16.0 stable zig handles the current SDK. If you see
a wall of `undefined symbol: _*` from a link, you are on the wrong zig.

The build also needs the Xcode command-line tools present (the native link finds the SDK via
`xcrun`).

## Runtime symptom of a bad signature

If nether boots to the point of setting up the guest and then dies creating the VM/vCPU
(HVF returns `HV_DENIED` / a `hv_*` error), the binary is not correctly entitled: re-run the
recipe and check `file` + the entitlement readback. A correctly signed binary prints the
usual boot/console output and reaches the guest login/agent.

## Reproducible HVF e2e (`scripts/e2e.sh`)

`scripts/e2e.sh` is one command from a clean checkout to a real-HVF end-to-end gate. Hosted
CI cannot run it (GitHub's macOS runners are VMs with no nested virtualization), so it runs
on real Apple Silicon. It:

1. builds native and codesigns (the automation above),
2. bakes a minimal forkable base from `examples/e2e-base.nether.toml`,
3. runs the authoritative in-repo warm-fork proof (`scripts/fork_serve.py`: boot -> snapshot
   -> warm fork -> serve), and
4. invokes both SDK e2e drivers (`~/nether-sdk-python`, `~/nether-sdk-typescript`) against the
   signed binary and the baked base.

Its exit code is tiered so a caller can separate the two failure classes:

- `0` all green;
- `1` the gate nether owns (build / sign / bake / fork-serve) failed - a real regression;
- `2` that gate is green but an SDK driver is red - integration is not yet green, not a nether bug.

`E2E_SKIP_SDK=1` runs only the owned gate; `E2E_KEEP=1` keeps the scratch base for inspection.

### Self-hosted CI verdict

Recommendation: **do not attach a self-hosted runner to this repo for e2e; run `scripts/e2e.sh`
on a dev Mac (or a dedicated, isolated Apple Silicon box) as the manual pre-merge gate for now.**

Why: a self-hosted GitHub Actions runner registered on a personal/Apple-Silicon machine executes
whatever workflow a triggering commit defines. On a public repo, a `pull_request` from a fork can
carry a modified workflow, so a fork PR would run arbitrary attacker code on the host with the
runner's privileges. That is the well-known self-hosted-runner RCE exposure, and it is not worth
it for a solo/small project. If a self-hosted e2e job is ever added, it must be gated to
`workflow_dispatch` (manual) and/or `push` on protected branches only, never `pull_request` from
forks, ideally with `runs-on: [self-hosted, macOS, ARM64]` on an ephemeral/throwaway box behind
an environment approval. Until that is set up deliberately, the hosted CI (unit + fuzz smoke,
three optimize modes) stays the automated gate and `scripts/e2e.sh` is the human-run HVF gate.

## Distribution signing and notarization

Everything above is ad-hoc signing, which is enough to *run* nether locally. Shipping a binary a
user downloads and runs without building is different: Gatekeeper quarantines an unnotarized
download, so distribution needs a Developer ID Application certificate, the hardened runtime
(`--options runtime`, mandatory for notarization), notarization (`notarytool submit`), and the
hypervisor entitlement surviving all of it.

What is proven (on macOS 26.5, Apple Silicon):

- **The hardened runtime does NOT strip the hypervisor entitlement.** Signing with
  `--options runtime` (via `SIGN_EXTRA="--options runtime" scripts/sign.sh`) yields
  `flags=0x10002(adhoc,runtime)` with the entitlement still embedded and `codesign --verify
  --strict` passing.
- **HVF still works under the hardened runtime.** The `fork_serve.py` warm-fork proof passes with
  a hardened-runtime-signed binary: boot, snapshot, and warm fork all succeed, so the kernel
  grants the hypervisor at runtime under the hardened runtime. This was the biggest unknown and it
  is disproven as a blocker.

What could not be proven on the dev machine (the real remaining gap):

- **End-to-end notarization + Gatekeeper acceptance.** This machine has only an *Apple Development*
  certificate and no stored notary credentials, so a Developer-ID-signed + notarized round trip
  cannot be run here. Closing it needs a paid **Apple Developer Program** membership ($99/yr) and a
  **Developer ID Application** certificate generated from it - flag this as a prerequisite; do not
  assume it exists (an "Apple Development" cert can come from a free personal team).

Open questions and current best answers (to confirm once the Developer ID cert exists):

- **Does `com.apple.security.hypervisor` need a provisioning profile for Developer ID?** Very likely
  no. It is freely embeddable ad-hoc (unlike profile-gated `com.apple.developer.*` entitlements) and
  survives the hardened runtime, which is strong evidence the entitlement-in-signature suffices.
  Confirm with one notarized round trip.
- **Can a bare CLI Mach-O be stapled?** Expect *notarize yes, staple no*. `notarytool` accepts a zip
  of the bare binary, but `stapler staple` attaches a ticket to a container (`.app` / `.dmg` /
  `.pkg`), not a bare executable. So the distributable form is a fork in the road: ship the bare
  binary notarized-but-unstapled (Gatekeeper checks online at first launch) or wrap it in a
  `.dmg`/`.pkg` for an offline stapled ticket. This is a UX decision for the install script, not a
  blocker.

Release-pipeline sketch (do NOT wire real secrets until the cert exists), for the P1.1 signed
one-line install:

```
on a Mac with a Developer ID Application cert + a notarytool keychain profile:
  zig build -Dtarget=native -Dcodesign=false          # build unsigned
  SIGN_IDENTITY="Developer ID Application: <NAME> (<TEAMID>)" \
    SIGN_EXTRA="--options runtime --timestamp" \
    scripts/sign.sh zig-out/bin/nether                # hardened-runtime Developer ID sign
  ditto -c -k --keepParent zig-out/bin/nether nether.zip
  xcrun notarytool submit nether.zip --keychain-profile <PROFILE> --wait
  # staple the container if shipping a .dmg/.pkg; a bare binary stays online-checked
  # upload zig-out/bin/nether (or the .dmg) as a GitHub Release asset; install.sh fetches + verifies
```

`scripts/sign.sh` already parameterizes the identity (`SIGN_IDENTITY`) and the hardened-runtime
flags (`SIGN_EXTRA`), so the same signing path covers ad-hoc dev, hardened-runtime experiments, and
the eventual Developer ID release.
