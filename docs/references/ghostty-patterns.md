# Ghostty as a reference (patterns worth stealing)

Ghostty (a terminal emulator in Zig) is not a dependency and not VMM prior art.
It is a top-tier Zig codebase whose architecture solves two problems Nether also
has: an embeddable core decoupled from its host, and a single library exposed to
both Zig and C consumers. This file records the patterns worth borrowing and
where they live, so we do not re-derive them.

Reference checkout: `~/ghostty` (full clone of ghostty-org/ghostty, with tags).
File paths below are relative to `~/ghostty/`. See "Using the clone" at the bottom
for the toolchain split and how to build the VT library.

There is also a real seam where Ghostty could become a dependency, not just an
example: its terminal core is a standalone VT library (pattern 2). That is the
candidate engine for a server-side console (web console, snapshot of console
state, grid-level golden tests) if that work ever lands. See
[../decisions.md](../decisions.md) D4/D5 and the platform track in
[../roadmap.md](../roadmap.md). For now: example only.

---

## 1. Comptime runtime swap (apprt) -> Nether's embeddable-core boundary

`src/apprt.zig`, `src/apprt/runtime.zig`, `src/apprt/{none,embedded,browser,gtk}.zig`

The core never names a concrete host. The platform layer (windowing, input,
clipboard) is one interface with comptime-selected implementations:

```zig
// src/apprt.zig
pub const runtime = switch (build_config.artifact) {
    .exe => switch (build_config.app_runtime) { .none => none, .gtk => gtk },
    .lib => embedded,        // libghostty consumers
    .wasm_module => browser,
};
pub const App = runtime.App;
pub const Surface = runtime.Surface;
```

The header comment states the goal exactly: "share as much of the core logic as
possible, and only reach out to platform-specific implementation code when
absolutely necessary."

**Nether application.** Today `main.zig` is the host and `root.zig` is the
library, by convention. Make it a hard compile boundary: a `host`/`apprt` seam so
the same core compiles unchanged as (a) a standalone exe with a default host, (b)
a lib swerver links (the `embedded` analog), (c) later a remote/headless target.
No host-specific code (stdin threads, termios, fd wiring) should live in the
device models; it belongs in a host implementation behind the seam. This is the
[thesis](../thesis.md) "embeddable core, allocator-injected" consequence made
structural.

**Adopt:** now, as framing. Cheap to set early, expensive to retrofit.

## 2. One library, two ABIs from a build flag -> the keystone for "swerver hosts Nether"

`src/terminal/lib.zig`, `src/lib/main.zig`, `src/terminal/c/`, `include/ghostty.h`

The same VT library is built with either a native Zig API or a C ABI, chosen at
build time:

```zig
// src/terminal/lib.zig
pub const target: lib.Target = if (build_options.c_abi) .c else .zig;
```

`src/lib/main.zig` holds the C-boundary machinery (`String`, `Buffer`,
`TaggedUnion`, enum/struct marshaling) and, crucially, comptime checks that the
Zig types match the C header: `structSizedFieldFits`, `checkGhosttyHEnum`. The
`terminal/c/` directory is the C-facing surface (result/error types in
`result.zig`, allocator handoff in `allocator.zig`, one file per exported type).

**Nether application.** This is the highest-leverage idea for the platform thesis.
Build the embeddable core once; swerver consumes the Zig API with zero marshaling
(Zig to Zig), and any foreign host gets a C ABI, from a single codebase. Decide
the shape now even if the C side is stubbed. The comptime "Zig struct matches the
C header" discipline is the same one Nether already applies to hand-rolled KVM
structs (`src/kvm.zig` ABI tests); here it is turned around onto Nether's own
*exported* API.

**Adopt:** now, as a decision and a stub. Defer the full C surface until a
non-swerver host actually needs it.

## 3. Mailbox concurrency + reader/writer split -> the evolution path for D3

`src/termio.zig`, `src/termio/{mailbox,Thread,Termio,message}.zig`,
`src/datastruct/main.zig` (BlockingQueue)

Termio is split into Termio (shared state) / Backend (physical IO, swappable) /
Mailbox / Thread, and is "built to be both single and multi-threaded." The
Mailbox is a tagged union over a bounded SPSC queue plus an async wakeup:

```zig
// src/termio/mailbox.zig
const Queue = BlockingQueue(termio.Message, 64);
pub const Mailbox = union(enum) {
    // unbounded: std.ArrayList(...)   // single-threaded / testing variant
    spsc: struct { queue: *Queue, wakeup: xev.Async },
};
```

The reader thread (the hot path: parsing VT) is kept lean; everything else
(events, mode changes, resize) is offloaded to the writer thread. `send()` even
handles the full-queue edge case by dropping a passed-in mutex, blocking-sending,
and relocking.

**Nether application.** The D3 per-device lock you just shipped is correct and
fine now. The *scaling* pattern is message passing: let one thread own a device's
state and have other threads send it messages through a bounded queue, instead of
sharing locked state. Two direct fits:

- The vCPU thread is Nether's hot path (Ghostty's reader-thread analog). Keep it
  doing as little as possible; offload to the I/O thread.
- The serial RX lock could become a queue: the I/O thread sends "RX bytes"
  messages, the vCPU drains them on its next exit (woken via eventfd). That
  removes the lock at the cost of a wakeup/poll latency. Interrupt injection
  (`signalMsi`) is *already* message passing (kernel-mediated).

The single-threaded variant of the same union means the core does not care how
the host threads it, which is exactly what "swerver decides the concurrency
model" (per-VM-per-worker, [thesis](../thesis.md)) wants.

**Adopt:** later, when lock contention or device count makes the lock model hurt.
Until then, hold the D3 discipline (one lock order, no lock across a syscall).

## 4. Event-loop I/O thread (libxev) -> where the blocking stdin thread goes next

`src/termio/Thread.zig` (xev.Loop, xev.Async, xev.Timer), `src/global.zig` (xev)

Ghostty's IO thread is an event loop (libxev: epoll/io_uring/kqueue), not a
blocking read. Cross-thread wakeups use `xev.Async` (eventfd underneath), and
timers handle coalescing and watchdogs.

**Nether application.** `stdinPump` currently blocks one thread on one fd. The
moment there is a second host input source (a second serial, vsock, a control
socket, a timer), switch to one I/O thread running an event loop rather than a
thread per fd. libxev is in the Zig ecosystem, and its `xev.Async` is the same
primitive as the eventfds already in `src/irqchip.zig`. The
[design](../design.md) already names "one I/O thread on epoll over eventfds" as
the target; this is the concrete way to build it.

**Adopt:** at the second host-side input source. Not before.

## 5. Comptime exactly-sized state-transition table -> the VT seam and Nether's own style

`src/terminal/parse_table.zig`, `src/terminal/Parser.zig`

The VT parser is the DEC ANSI state machine (vt100.net) implemented as a
comptime-generated, exactly-sized `[u8][State]Transition` table, with comptime
detection of invalid transitions:

```zig
// src/terminal/parse_table.zig
pub const table = genTable();          // exactly-sized at comptime
const OptionalTable = genTableType(true); // accumulate + detect invalid transitions
```

**Nether application.** Two levels. Specifically: if the server-side console seam
(pattern 2, D5 grid-level golden tests, web console) ever lands, this is the
reference VT parser to copy. Generally: the technique (build an exactly-sized
dispatch table at comptime with completeness validation) fits how Nether already
comptime-generates ioctl numbers (`src/kvm.zig`) and the memory map
(`src/memmap.zig`). The DEC parser is small and well-specified, a weekend not a
project.

**Adopt:** done. The parser slice (`Parser.zig` + `parse_table.zig`) is vendored
and ported to 0.16 in `src/vt/` (see `src/vt/PORTING.md`), and the grid is owned:
`src/vt/Screen.zig` is a Nether-authored screen model on top of the parser
(fixed-size, pointer-free cells, deferred autowrap, the CSI/SGR/ED/EL/cursor set
a shell emits). Both are fuzz-smoked. Remaining grid work is scrollback and the
alternate screen, deferred until a real need (see pattern 6).

## 6. Paged + ref-counted + pool-allocated storage -> snapshot-fork discipline

`src/terminal/PageList.zig`, `src/terminal/page.zig`,
`src/terminal/ref_counted_set.zig`, `src/terminal/bitmap_allocator.zig`

The screen and scrollback are stored as fixed-size pages in a linked list, with a
bitmap pool allocator and ref-counted styles. The result serializes cleanly and
can be shared copy-on-write.

**Nether application.** Conceptual inspiration, not code to lift. Snapshot-fork
(boot once, clone per request) is the edge product ([thesis](../thesis.md)), and
it wants device/guest state that is fixed-size, pool-allocated, ref-countable,
and serializable by construction, from Phase 3 forward rather than retrofitted.
Ghostty's storage layer is a worked example of that discipline. Nether's own
`src/vt/Screen.zig` follows it: a fixed-size, pointer-free live grid plus a
scrollback ring of evicted rows, all serializable by copy. Ghostty's heavier
machinery (true paging of the scrollback, ref-counted styles) is the further
growth path if memory pressure (very deep scrollback, many forked snapshots)
makes the flat ring too costly.

**Adopt:** done for v1 (serializable grid + scrollback ring). Add paging /
ref-counted styles only under real memory pressure.

---

## What does NOT transfer

The renderer (GPU text), font shaping/atlas, input/keymap, clipboard, kitty
graphics, shell integration. These are terminal-app concerns with no VMM analog.
A VMM display path (virtio-gpu, roadmap Phase 5) is a generic GPU surface
(`zig-webgpu`), not terminal-cell rendering; Ghostty's renderer is coupled to its
own grid and does not help there.

## Summary: adopt-now vs trigger-based

| Pattern | Nether use | When |
|---|---|---|
| 1. apprt comptime swap | embeddable-core compile boundary | now (framing) |
| 2. one core, Zig + C ABI | swerver-native + foreign-host embed | now (decide + stub) |
| 3. mailbox concurrency | D3 evolution past per-device locks | lock pain / device count |
| 4. libxev event loop | I/O thread past blocking read | 2nd host input source |
| 5. comptime VT table | server-side console / D5 grid tests | done: parser vendored + grid v1 (src/vt/) |
| 6. paged/ref-counted store | snapshot-fork device state | grid + scrollback ring done; ref-counting under memory pressure |

---

## Using the clone

**No git submodules.** Dependencies are Zig packages (`build.zig.zon`, mostly
`lazy`) plus C libs vendored under `pkg/`. Prime the package cache with
`zig build --fetch` (already done; ~270M in `~/.cache/zig/p`).

**Toolchain split (important).** Ghostty pins **Zig 0.15.2** (see `flake.nix`),
Nether targets **0.16.0 stable**. They are not interchangeable: 0.16 changed
`std.Io.Dir.readFileAlloc` (3 -> 4 args, breaks Ghostty's `build.zig`), `PROT`,
and the `Mutex` location. 0.15.2 is installed at `~/Library/zig/0.15.2`; build
Ghostty with it, Nether with `~/Library/zig/0.16.0`.

**The split does NOT block consumption.** `libghostty-vt` is a C library
(`.a`/`.dylib` + headers) with a C ABI, so Nether (built with 0.16.0) can link it
regardless of the Zig version that produced it. Build Ghostty once with 0.15.2,
link the resulting C library into Nether.

**Build the VT library (macOS):**

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  ~/Library/zig/0.15.2/zig build -Demit-lib-vt -Demit-xcframework=false
# -> zig-out/lib/libghostty-vt.{a,dylib}, zig-out/include/ghostty/vt/*.h
```

`DEVELOPER_DIR=...CommandLineTools` is needed so the Zig build runner links
libSystem (with Xcode.app selected it fails to). `-Demit-xcframework=false` skips
the XCFramework so the full Xcode/iOS SDK is not required. The full macOS *app*,
by contrast, does need Xcode.app + `xcodebuild`.

**The console-seam C API** (`zig-out/include/ghostty/vt/`, the entry point for a
server-side console, console-state snapshot, or D5 grid tests):

- `ghostty_terminal_new(const GhosttyAllocator*, ...)` / `ghostty_terminal_free`
  - the allocator is injected across the C boundary, matching Nether's
    allocator-injection contract.
- `ghostty_terminal_vt_write(t, bytes, len)` - feed guest serial output in.
- `ghostty_terminal_resize`, `_reset`, `_mode_get/set`, `_scroll_viewport`.
- `ghostty_cell_get`, `ghostty_grid_ref_*` - read the screen grid out (cells,
  styles, graphemes, hyperlinks) to ship to a frontend or assert on.

`src/terminal/c/AGENTS.md` documents the C ABI discipline (opaque pointers for
long-lived objects, sized structs with `GHOSTTY_INIT_SIZED`, `TaggedUnion`
conversion). That is the concrete reference for pattern 2 when Nether exposes its
own C ABI.
