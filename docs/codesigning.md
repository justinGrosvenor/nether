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

## The recipe (copy-paste)

```sh
cd ~/nether
ZIG=/Users/justin/Library/zig/0.16.0/zig      # 0.16.0 STABLE - see "Toolchain" below

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

Use **zig 0.16.0 stable** (`/Users/justin/Library/zig/0.16.0/zig`), not whatever `zig` is on
`PATH`. On this machine the `PATH` zig is an older `0.16.0-dev` that (a) lacks
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
