# Control protocol v2 - "frame everything" (PROPOSAL)

Status: **PROPOSED** (2026-07-04). Owner: NETHER. Affects consumers: `tools/nether-ctl.c`,
swerver `control_client`, `a private path` codec, `a private path`. Requires a
`proto_version` bump (1 -> 2) and coordinated consumer updates. This doc is the spec to
review before implementing; nothing here is built yet.

## 1. Why

Today (v1) a reply is one of two line shapes for the "command/ack" commands:

- **Framed**: `<body> 0x1e <exit> \n` - `__info__`/`__stats__`/`__help__` and shell commands.
- **Bare**: `ERR <reason>\n` or `OK <reason>\n` with **no `0x1e`** - `__shutdown__`,
  `__snapshot__`, `__put__`, `__get__`, and every control-plane rejection (unknown command,
  read-only observer, agent-not-connected, too-many-clients, ...).

The two are indistinguishable **at the start of the reply**: a bare `ERR read-only observer`
can come back for a command a client expected to be framed, and a shell command's *output*
can itself begin `ERR `/`OK `. v1 resolves this with a **timing heuristic** (the reference
client and every consumer wait ~500 ms - `SETTLE_MS` - to see whether a `0x1e` trailer
follows). That heuristic is the protocol's one real wart:

- **It can truncate a real reply.** A framed shell reply whose body begins `OK `/`ERR ` and
  whose `0x1e` trailer lags >500 ms (a slow/streaming producer, or a deliberately malformed
  guest - the stated threat model) is mis-delivered as a *bare* reply: the true multi-line
  output and exit code are silently discarded. (Found in the `the console` codec review,
  2026-07-04, `connection.ts` settle path.)
- **It costs latency.** `__snapshot__` (socket stays open) forces every consumer to wait a
  full idle/settle window (~500 ms-2 s) before resolving, even though the `OK` line arrived
  immediately.
- **Every consumer must re-implement it** (a settle timer + a bare-line guard + a per-command
  "is this framed?" table). It is the single most error-prone part of writing a client.

## 2. Goal

Make **every line-oriented reply framed**, so a consumer reads *any* command/ack reply with
**one loop and no timer**: read until a raw `0x1e`, then the exit code, then `\n`. Delete the
settle heuristic entirely. Keep the streamed/binary replies (logs, screen, framebuffer) as
they are - they are read in a mode that already knows their shape.

## 3. The change

### 3.1 Framed becomes universal for command/ack replies

In v2, these replies **all** end with the `0x1e <exit> \n` trailer:

| Command(s) | v1 shape | v2 shape |
|---|---|---|
| `__info__`, `__stats__`, `__help__` | framed (exit 0) | framed (exit 0) - unchanged |
| shell command (`<other>`) | framed (guest exit) | framed (guest exit) - unchanged |
| `__shutdown__` | bare `OK ...\n` | **framed** `OK ...\n 0x1e 0 \n` |
| `__snapshot__`, `__put__`, `__get__` | bare `OK`/`ERR` | **framed** (exit 0 on OK, `<0` on ERR) |
| any control-plane `ERR ...` (unknown command, observer, agent-not-ready, too-many-clients) | bare `ERR ...\n` | **framed** `ERR ...\n 0x1e <0 \n` |

So in v2, `is_framed(cmd)` is true for **everything except the streamed commands** -
i.e. true for `__info__`/`__stats__`/`__help__`/`__shutdown__`/`__snapshot__`/`__put__`/
`__get__` and all shell commands; false only for the streamed set below.

### 3.2 Streamed replies stay self-delimiting (unchanged)

`__events__`, `__cmdlog__`, `__netlog__`, `__screen__`, `__screendiff__` (self-delimiting
text) and `__frame__`, `__framediff__` (length-implicit binary) keep their v1 shape: the
consumer reads them to an idle gap / EOF in a mode it chose for that command. Framing them
with a raw `0x1e` delimiter is wrong - a PPM/tile blob contains `0x1e` bytes, and logs stream
without an in-band terminator. **These commands are never subject to the bare/framed
ambiguity** because a client only reads them in streamed mode.

An *error* for a streamed command (`__netlog__` with `net` off, `__screen__` with render off,
`__frame__` with no gpu, ...) is a framed `ERR` line (see 3.4) - short, and distinguishable
from a real payload by its `ERR ` prefix, which no success payload begins with (a PPM starts
`P6`, a log with its header line). A streamed-mode consumer that reads its payload to
idle/EOF and finds instead a single `ERR ...0x1e<exit>\n` frame treats it as the error.

### 3.3 Body escaping is unchanged

The body-before-the-trailer is still delimiter-escaped so it can never contain a raw `0x1e`
(guest command output: `0x1e`/`0x1f` -> `0x1f,(b^0x40)`, per `tools/agent.c`). Host-generated
`ERR`/`OK` bodies are trusted ASCII and contain no `0x1e`/`0x1f`, so they need no escaping;
the framer still guarantees the invariant "a raw `0x1e` appears only in the trailer." The
R2b unforgeability property is preserved untouched.

### 3.4 Exit-code semantics: negatives are control-plane errors

A byte-range exit (`0..255`) already means "a report (0), or a shell command's real exit."
v2 reserves **negative** trailer codes for **control-plane errors**, which POSIX exits can
never be - so a consumer separates "the guest command ran and exited N" from "nether rejected
or failed the command" with a single sign test, no string matching, no collision:

| Trailer exit | Meaning | Body |
|---|---|---|
| `0` | success: a report, an `OK` ack, or a shell command that exited 0 | report / `OK ...` / command stdout |
| `1..255` | a **shell command's** real exit code | command stdout+stderr |
| `-1` | a **control-plane error** (generic) | `ERR <reason>` |

`-1` is the single control-error code for v2.0; the reason string carries the detail (as
today). If consumers later want to branch without parsing the string, distinct negatives can
be assigned (`-2` unknown command, `-3` observer-denied, `-4` agent-not-ready, ...) as an
additive v2.x refinement - a consumer that only sign-tests keeps working.

Rationale for negative (vs a sentinel like `255`): a shell command can legitimately exit
`255`, so a positive sentinel collides with a real guest exit; a negative never does.

### 3.5 Worked example

```
v1  __shutdown__  ->  "OK shutting down\n"                    (bare; read to idle/EOF)
v2  __shutdown__  ->  "OK shutting down\n\x1e0\n"             (framed; read to 0x1e, exit 0)

v1  (observer) ls  ->  "ERR read-only observer...\n"          (bare; 500ms settle to detect)
v2  (observer) ls  ->  "ERR read-only observer...\n\x1e-1\n"  (framed; exit -1 = control error)

v1  ls (ok)        ->  "<files>\x1e0\n"                        (framed; unchanged)
v2  ls (ok)        ->  "<files>\x1e0\n"                        (framed; unchanged)
```

Consumer read loop, v2 (framed-category commands): read bytes until a raw `0x1e`; then read
the ASCII integer to `\n`; `exit >= 0` -> result (body is the reply), `exit < 0` -> control
error (body is `ERR <reason>`). No timer. No bare/framed branch.

## 4. Backward compatibility

v2 is a wire change, so it is gated on `proto_version`. But a v1 consumer talking to a v2
nether **mostly still works**, which makes rollout safe:

| v1 consumer path on a v2 nether | Behavior | Verdict |
|---|---|---|
| framed command that gets a control `ERR` (was bare) | the `0x1e` now arrives immediately, so the consumer's bare-guard `memchr(RS)` sees it and reads the frame instead of settling - it gets a framed `ERR` with a nonzero (negative) exit | **compatible** (fails the command, as before; now with an exit code) |
| `__shutdown__` (read unframed) | socket closes (EOF); body is `OK shutting down\n\x1e0\n` - trailing `\x1e0\n` is cosmetic in the body | **compatible** (checks `OK` prefix) |
| `__snapshot__` (read unframed) | still waits its idle window, then body carries the trailing `\x1e0\n` | **compatible**, cosmetic trailer, no latency win until updated |
| shell command | unchanged (framed in both) | **identical** |

The handshake is version-safe: `__info__` is framed in **both** v1 and v2, so a consumer reads
it the same way and learns `proto_version` before it has to pick a read strategy.

A **v2-aware** consumer must still handle v1 servers until every nether is upgraded: read
`proto_version` from `__info__`, and if `1`, keep the settle-timer + bare-guard path; if `>=2`,
use the uniform framed loop and treat `__shutdown__`/`__snapshot__`/`__put__`/`__get__` as
framed. This dual-path period ends when all deployed nether are v2.

## 5. Consumer migration

- **`tools/nether-ctl.c`** (reference): add v2 to `is_framed()` (shutdown/snapshot/put/get
  become framed); gate the `bare_status_line` settle path on `proto_version==1`. ~20 lines.
- **swerver `control_client`**: same shape change; drop `SETTLE_MS` on v2.
- **`a private path` codec** (`clients/nether/codec.ts`, `connection.ts`): `isFramed()`
  returns true for the ack commands on v2; delete the settle timer on v2 (fixes the
  truncation bug found in review directly). `unescapeBody`/frame-finding are unchanged.
- **`a private path`**: uses `__info__`/`__shutdown__`; gains the uniform loop.

All four already read `proto_version` from the `__info__` handshake, so the version gate has a
home. Nether ships one version at a time (no per-client downgrade); consumers adapt off
`proto_version`.

## 6. Nether implementation sketch

- Bump `PROTO_VERSION` 1 -> 2 (`src/agent/control.zig`). `__info__`/`__help__` report it.
- Replace the bare `reply(c, "ERR ...")` / `reply(c, "OK ...")` sites (41 today) with framing
  helpers:
  - `replyOk(c, body)` -> `writeAll(body); writeFrame(c, 0)`.
  - `replyErr(c, body)` -> `writeAll(body); writeFrame(c, -1)`.
  - `writeFrame(c, exit)` -> writes `0x1e`, the ASCII (possibly negative) exit, `\n`.
- **Recommended (Option A): frame all `ERR`/`OK` uniformly** - one mechanical change; the
  ~12 streamed-command error sites also become framed `ERR` (harmless: a streamed consumer
  detects them by the `ERR ` prefix, 3.2). Simplest to implement and to reason about ("every
  `ERR`/`OK` is framed").
  **Alternative (Option B): keep streamed-command errors bare** - the 12 streamed error sites
  call a `replyBare()`; the rest frame. Preserves "a streamed reply never contains a `0x1e`"
  at the cost of per-site category awareness. Prefer A unless a consumer needs B.
- The framed-report path (`__info__`/`__stats__`/`__help__`) and the guest-command relay are
  already framed - no change.

## 7. Tests

- Flip the wire-shape assertions in the integration-contract test (`control.zig`,
  "control protocol: introspection replies, versioning, observer gating"): the bare `ERR`/`OK`
  replies that today assert **no `0x1e`** must assert a **framed trailer** with a negative exit
  for `ERR` and `0` for `OK`. `__info__`/`__stats__`/`__help__` keep the `0x1e0\n` assertion.
- Add: an observer-denied drive command frames with exit `-1`; `__shutdown__` OK frames with
  exit `0`; the streamed logs (`__events__`) still carry no trailer (Option A: their *error*
  path frames, their success path does not).
- Consumer side (out of nether): the settle-timer truncation case (a framed body starting
  `OK `/`ERR ` with a late trailer) must now decode correctly with no timer - the regression
  the whole change exists to kill.

## 8. Alternatives considered

- **Leave it at v1** (settle heuristic). Zero migration, but keeps the truncation hazard and
  the per-consumer complexity. Rejected: the protocol now has 4 consumers; the wart compounds.
- **Length-prefix every reply** (a `<len>\n<bytes>` header on everything, including binary and
  streamed). Fully uniform and escape-free, but a much larger change: every reply site,
  chunked length-framing for streaming logs, and a total break of the `0x1e`+escape model that
  the R2b unforgeability proof rests on. Rejected as disproportionate; the negative-exit frame
  reuses the existing, proven framing.
- **Advertise per-command shape in `__help__`/`__info__`** (so a consumer configures
  `is_framed()` at runtime instead of hardcoding). Solves discoverability but not the
  bare/framed timing ambiguity - a consumer still needs the settle timer for the bare replies.
  Orthogonal; could layer on later, but v2 makes it unnecessary for the ack commands.

## 9. Rollout

1. Land v2 in nether behind the `PROTO_VERSION=2` bump + framed replies + flipped tests.
2. Update `tools/nether-ctl.c` (reference) in the same change, dual-path on `proto_version`.
3. Consumers (swerver, console, supervisor) update to the dual-path loop at their own pace -
   v1 clients keep working against v2 nether (section 4), so there is no lockstep requirement.
4. Once all consumers are v2-aware, the v1 settle-timer paths can be deleted everywhere.

## 10. Open questions

- **Distinct negative codes now or later?** v2.0 uses a single `-1`; assigning `-2/-3/-4` per
  error class is additive and can wait for a consumer that wants to branch without string
  matching.
- **Option A vs B for streamed-command errors** (section 6) - A is simpler; B preserves
  "streamed replies never contain `0x1e`." Pick before implementing.
- **Do we ever need framed *streaming*?** If a future consumer wants a hard end-of-stream
  marker on `__events__`/`__screen__` (instead of idle-gap), that is a separate length- or
  sentinel-framed streaming design, out of scope here.
