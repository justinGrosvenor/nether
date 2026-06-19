# Vendored VT parser: provenance and porting

This directory is the VT (escape/control-sequence) parser, vendored from Ghostty
and ported to Nether's toolchain. Strategy: **port the parser, own the grid** (see
[../../docs/references/ghostty-patterns.md](../../docs/references/ghostty-patterns.md)).
We take Ghostty's hard, stable parser (the DEC ANSI state machine plus its
comptime transition table) and will build our own screen grid on top, sized to
Nether's needs, rather than vendoring Ghostty's ~46k-LOC grid.

## Upstream

- Repo: `ghostty-org/ghostty`
- Commit: `5d0a82ba337368f5632ffa6ce4d7c558fa2de9ff` (`git describe`: tip-2-g5d0a82ba3)
- Fetched: 2026-06-19
- Reference checkout on this machine: `~/ghostty`

## Files

| File | Origin |
|---|---|
| `parse_table.zig` | Ghostty `src/terminal/parse_table.zig`, verbatim (no changes) |
| `Parser.zig` | Ghostty `src/terminal/Parser.zig`, with the small edits below |
| `osc.zig` | **Nether-authored.** NOT Ghostty's. A minimal zero-alloc OSC parser |

## Changes from upstream (`Parser.zig`)

All edits are small and localized, so re-applying them after an upstream pull is
a quick, mechanical diff:

1. Removed the debug `format` methods on `Action.CSI`, `Action.ESC`, and `Action`
   (logging only; they used `*std.Io.Writer` / `printValue` and are not needed
   for parsing).
2. Removed the `std.valgrind.runningOnValgrind()` block in `init()`. With it gone
   `result` is never mutated, so it became `const result` (Zig 0.16 requires it).
3. Changed one `log.warn` from the `{f}` format specifier (which called the
   removed `format`) to a plain `{c}`.
4. Dropped the OSC color-operation tests (`osc: 112`, `osc: 104`); Nether's
   `osc.zig` does not interpret color operations. The title-OSC tests are kept.

## `osc.zig` (replacement, not a port)

Ghostty's `osc.zig` pulls in kitty-graphics colors, the C-ABI `lib` helpers, and
OSC sub-parsers (clipboard, hyperlinks, palette). Nether's serial console needs
none of that, so `osc.zig` here is a small zero-alloc parser that satisfies
exactly the interface `Parser.zig` calls (`init`/`deinit`/`reset`/`next`/`end`)
and recognizes the title commands (OSC 0/1/2), surfacing everything else as
`raw`. Grow it deliberately if a real OSC need appears.

## Toolchain note

The 0.15 -> 0.16 port needed essentially one change (the `const` above): this
source already used modern Zig (`@typeInfo(...).@"enum"`, `*std.Io.Writer`).
Ghostty's 0.15.2 pin is about its *build system*, not the terminal source. Nether
builds this with stable 0.16.0 like the rest of the tree.

## Updating

1. `cd ~/ghostty && git pull`, note the new commit sha.
2. Diff `src/terminal/Parser.zig` and `src/terminal/parse_table.zig` against the
   copies here; re-apply the four edits above.
3. Leave `osc.zig` alone (it is ours).
4. `zig build test` (with stable 0.16.0). Update the commit sha at the top.

The DEC parser is a frozen spec, so upstream changes to these two files are rare.
