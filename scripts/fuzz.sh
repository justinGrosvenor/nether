#!/bin/sh
# Double fuzz run: a deterministic pass then a random pass over the guest-facing parsers.
#
#   pass 1  deterministic (fixed seeds): a reproducible regression baseline. Identical
#           inputs every run, so a failure here is a known-input regression.
#   pass 2  random seed: fresh inputs each run, so running it repeatedly during
#           development accumulates new coverage over time. A failure prints the seed to
#           reproduce it exactly.
#
# Both passes are short (the same bounded smoke harnesses as `zig build test`). This is an
# intermediate step, not a nightly: run it while you work. For coverage-guided fuzzing use
# `zig build fuzz --fuzz`.
#
# Override the toolchain with ZIG=/path/to/zig (defaults to `zig` on PATH; pin 0.16.0).
set -eu

ZIG="${ZIG:-zig}"

echo "[fuzz] pass 1/2: deterministic (fixed seeds)"
"$ZIG" build test

# A fresh 64-bit seed each run: every harness's stream shifts by this salt (XORed into its
# per-target base seed, so targets stay distinct), exploring inputs the fixed pass never hits.
SEED=$(od -An -tu8 -N8 /dev/urandom | tr -d ' ')
echo "[fuzz] pass 2/2: random seed (NETHER_FUZZ_SEED=$SEED)"
NETHER_FUZZ_SEED="$SEED" "$ZIG" build test

echo "[fuzz] both passes green."
echo "[fuzz] reproduce a pass-2 failure with: NETHER_FUZZ_SEED=$SEED $ZIG build test"
