# Contributing to nether

Thanks for your interest. nether is an early, fast-moving project; issues, ideas, and
pull requests are all welcome.

## Developer Certificate of Origin (DCO)

Contributions are accepted under the [Apache-2.0](LICENSE) license. To keep the
provenance of the code clean, every commit must be **signed off** under the
[Developer Certificate of Origin](https://developercertificate.org/): by adding a
`Signed-off-by` line you certify you wrote the change (or have the right to submit it)
and agree it may be distributed under the project license.

Sign off automatically with:

```sh
git commit -s
```

which appends `Signed-off-by: Your Name <your@email>` (matching your git identity).

## Prerequisites

- **Zig 0.16.0** ([ziglang.org/download](https://ziglang.org/download/)). The build
  pins `minimum_zig_version` and has no external dependencies.
- For the primary (HVF) backend: an **Apple Silicon Mac**. HVF needs a hypervisor
  entitlement, so a native build must be codesigned before it can run.
- The x86/KVM reference backend needs a Linux host with `/dev/kvm`.

## Build, test, run

```sh
zig build -Dtarget=native                       # build the native binary
codesign --sign - --entitlements nether.entitlements --force zig-out/bin/nether
zig build test                                  # run the test suite (incl. fuzz smoke)
./scripts/fetch-guest-image.sh                  # fetch/build a bootable guest image
./zig-out/bin/nether                            # boot it
```

See [`docs/running-on-hvf.md`](docs/running-on-hvf.md) for the full HVF path and
[`docs/codesigning.md`](docs/codesigning.md) for the signing details.

## Style and expectations

- **Match the surrounding code.** nether's source is deliberately, densely commented —
  comments explain *why*, not just *what*, and document the threat model and the tricky
  invariants. Keep that standard: a non-obvious change should say why it's correct.
- **Keep the tests green** on Zig 0.16.0 stable (`zig build test`). Add tests or a fuzz
  target for new guest-facing parsing surface — malformed guest input is the primary
  threat model (see [SECURITY.md](SECURITY.md)).
- **Small, focused commits** with a clear message: a one-line summary, then the *why*.
- If a change affects runtime behavior, exercise it end to end (boot a guest, drive the
  path) — not just the type-checker. Several `scripts/*.py` proofs show the pattern.

## Reporting bugs and security issues

- Functional bugs: open a GitHub issue with repro steps, config, and output.
- **Security / escape / memory-safety** issues: do **not** open a public issue — follow
  [SECURITY.md](SECURITY.md).
