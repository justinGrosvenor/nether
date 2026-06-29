# Nether control protocol

The control socket is the integration contract between the platform (swerver) and a
running sandbox. The platform spawns one `nether` process per sandbox, points it at a
Unix-domain socket via `control_socket=<path>` in `nether.conf`, and drives the sandbox
over that socket. This is the stable surface to build against; everything else
(virtio devices, the in-guest agent, the boot path) is implementation detail.

The current version is **`proto_version=1`** (reported by `__info__`, and in `__help__`).
Bump it on any breaking change to the command set or wire format. The command list is
also discoverable at runtime via `__help__`, so a client can self-check.

## Connecting

```
control_socket=/tmp/nether.sock     # in nether.conf; also enables control mode
```

The socket is owner-only (peer-uid checked). The **first** client to connect is the
*primary* and may drive the sandbox (run commands, transfer files, shut down). Later
clients are read-only *observers*: they may issue the introspection/observe queries but
not drive the sandbox. Send one command per line (`\n`-terminated).

**Disconnect is safe.** A client disconnecting - even the primary mid-command - never
affects the running sandbox: the write to the gone socket is absorbed (SIGPIPE is
ignored), the primary slot is released, and the next client to connect becomes the new
primary and can resume driving. So the platform can crash, restart, and reattach to a
live sandbox. A sandbox with no client is reclaimed only by `idle_timeout_s` (govern) or
an explicit `__shutdown__`; it is never torn down merely because the controller left.

**A wedged reader cannot freeze the guest.** Because the relay writes a command's output
to the primary socket, a primary that connects but *stops reading* would otherwise back up
the relay -> agent -> vCPU chain and stall the guest. So a write that blocks on a full
socket buffer for more than ~5s declares that client wedged and drops it (the slot reopens
for a fresh primary). A normally-reading client never hits this - the control socket is
local IPC, drained in microseconds - so read the streamed reply promptly (the serial
request/response model already requires it) and a slow consumer self-heals by reconnecting.

**Reference client.** `tools/nether-ctl.c` is the canonical implementation of this
protocol - the proto-version handshake, sending a command, and reassembling the framed
reply (it propagates the guest command's exit code). Build it on the host with
`cc -O2 tools/nether-ctl.c -o nether-ctl`, then `nether-ctl <socket> __info__` or
`nether-ctl <socket> <command...>`. An integrating client (e.g. swerver) can mirror its
`read_reply` framing logic directly.

## Reply shapes

- **Reports** (`__info__`, `__stats__`, `__help__`) end with a `0x1e` byte then `0\n`
  (the agent's `[exit N]` frame, here always exit 0) so a client knows the reply is
  complete.
- **Logs** (`__events__`, `__cmdlog__`, `__netlog__`) are self-delimiting: a header line
  carries a count/cursor, followed by that many records.
- **Binary** (`__frame__`, `__framediff__`) write raw bytes on the socket (a PPM image /
  tile records); the report tells you the length.
- **Shell commands** (anything not starting with `__`) stream the command's stdout/stderr
  then a `0x1e<exit-code>\n` trailer.
- **Errors / acks** are a single `ERR <reason>\n` (or `OK <reason>\n` for `__shutdown__`/
  `__put__`/`__get__`) line. These are **unframed** - no `0x1e`.

### Framing invariant (read this if you read until `0x1e`)

The reply shapes are NOT uniform, and the trap is that an **`ERR <reason>\n` is unframed
and can come back for a command you expected to be framed**: an unknown/typo'd `__verb__`,
`ERR read-only observer` (you're not the primary), or `ERR too many control clients`. A
client that blocks until `0x1e<exit>\n` would then **hang** waiting for a frame that never
arrives (until its own timeout).

So the invariant a driving client must encode: a reply to a command is *either* framed
(ends `0x1e<exit>\n`) *or* a single bare `ERR `/`OK ` line. **Guard for it:** while
reading toward the `0x1e`, if the buffer is a complete line starting with `ERR ` (or
`OK `) and no `0x1e` has appeared, treat it as a terminal reply and fail fast (non-zero) -
do not keep waiting. To avoid mistaking a command whose *output* begins with `ERR ` for a
control error, settle briefly first: a real command's `0x1e` trailer follows its output
immediately, so a short grace (the reference client uses 500 ms) disambiguates. The
reference client `tools/nether-ctl.c` (`read_reply` + `bare_status_line`) implements
exactly this; mirror it. (The logs/binary replies are unframed too, but a client reads
those in a mode that knows their shape; the hazard is specifically the unexpected `ERR`.)

### Readiness

The socket accepts connections **before the guest finishes booting**. The host-intercepted
queries (`__info__`, `__stats__`, `__help__`) answer immediately. A *driving* command
(shell command, `__put__`/`__get__`) needs the in-guest agent, which connects partway
through boot, so an early command waits for it - bounded (default 30s). A guest that never
connects (a broken image) makes the command fail with `ERR agent not connected (guest not
ready)` rather than blocking forever. So a client can either just send its command (it
parks until the agent is up) or, to distinguish "booting" from "broken", treat that ERR as
a fast failure (see the framing-invariant guard above).

### Reserved namespace

`__name__` is reserved for control commands. A line that starts with `__` but isn't a
recognized command (a typo, or a Tier-2 verb mistaken for a control command) is rejected
with `ERR unknown command ...` rather than forwarded to the guest. So a workload/agent
verb sent over this socket **must not** be `__`-prefixed: send a plain shell command (for
the stock guest agent) or your agent's own non-`__` verb. `__put__`/`__get__` are the only
`__` commands that take arguments.

### Output bound (a command's reply is frame-safe even when truncated)

A relayed command's stdout/stderr is capped at **`max_output_bytes`** (default **1 MiB**;
`0` in `nether.conf` = unlimited). When a command exceeds it, the body is truncated, a
one-time `\n...[output capped]\n` marker is inserted, and **the `0x1e<exit>\n` trailer is
still sent** - so the reply is *always a complete frame* and the exit code *always* arrives,
even for a runaway or hostile command. Large payloads should move over `__get__` (file
transfer), not command stdout.

This is one end of a two-sided contract (the other is the driving client's read buffer):

- **Nether truncates at a frame boundary.** It bounds the *body*, never the trailer. So a
  client can always read to `0x1e<exit>\n` and get a well-formed reply + exit code.
- **The client should drain to the frame boundary**, not to its own read cap. Because the
  trailer always arrives, a client whose buffer is smaller than `max_output_bytes` must keep
  reading (discarding overflow) until `0x1e<exit>\n` rather than stopping mid-body - else it
  clips the frame and corrupts the next reply. Sizing the client cap `>= max_output_bytes`
  avoids any discard; either way the frame stays intact.

`__info__` reports the effective `max_output_bytes` so a client can size its buffer to match.

### Concurrency on the primary socket

The primary socket carries both host-intercepted query replies and the streamed reply of
a relayed command, written from different threads. Issue **one command at a time**: send a
query (`__stats__`, etc.) only between commands, not while a command's reply is still
streaming, or the byte streams interleave. The serial request/response model (send a
line, read to its `0x1e<exit>\n` trailer, then send the next) is the contract.

## Commands

### Read-only (any client)

| Command | Reply | Purpose |
|---|---|---|
| `__info__` | report | Static capabilities + limits: `proto_version`, backend, arch, cpus, ram_mb, net/firewall/gpu, the govern caps (`max_runtime_s`, `max_cpu_s`, `idle_timeout_s`, `net_rate_kbps`, `max_output_bytes`), and `x402` (settlement mode on/off). |
| `__stats__` | report | Live usage: `uptime_ms`, `cpu_ms`, `mem_peak_mb`, `ram_mb`, `cpus`, `commands`, `bytes_in/out`, `net_tx/rx_bytes`, `net_blocked`. |
| `__events__ [seq]` | log | Unified event timeline (CMD/NET/LIFE). No arg dumps the retained ring; `__events__ <seq>` returns only events after that sequence number (the cursor from the previous `EVENTS <seq>` header) for incremental polling. |
| `__cmdlog__` | log | Per-command audit: `<ms> exit=<code> cpu_ms=<n> <command>`, oldest-first. |
| `__netlog__` | log | Egress audit: `<ms> <TCP\|UDP> <ip>:<port> <ALLOW\|BLOCK>`, oldest-first. Requires `net=1`. |
| `__screen__` | report | Terminal snapshot (scrollback + live grid), rendered server-side. Requires control mode. |
| `__screendiff__` | report | Terminal rows changed since the last call (full screen on first call). **Primary-only** (per-client diff state). |
| `__frame__` | binary | The virtio-gpu scanout as a binary PPM. Requires `gpu=1`. |
| `__framediff__` | binary | Framebuffer tiles changed since the last call. **Primary-only**. Requires `gpu=1`. |
| `__help__` | report | The command list (this table, abbreviated). |

### Primary client only (drive the sandbox)

| Command | Reply | Purpose |
|---|---|---|
| `__shutdown__` | `OK shutting down\n` | Clean teardown: the guest stops via its power-off path and the process exits (emitting the final usage bill). |
| `__snapshot__ [path]` | `OK`/`ERR` | Capture a fork-source base snapshot on demand (HVF only): quiesce the guest, write full machine state to `path` (default `nether.snap`, confined to the transfer jail), and resume - the sandbox keeps running. The reply blocks until the file is on disk, so the platform knows the base is ready to fork. `ERR snapshot not supported on this backend` on KVM. |
| `__put__ <hostpath> <guestpath>` | `OK`/`ERR` | Push a host file into the guest. Bytes move over vsock with length framing (binary-safe). Host path is confined to the transfer jail. |
| `__get__ <guestpath> <hostpath>` | `OK`/`ERR` | Pull a guest file to the host. Same jail + framing. |
| *(anything else)* | framed | Run the line as a shell command in the guest; output streams back, then `0x1e<exit>\n`. Metered as a command. |

## Lifecycle and settlement

Every session ends with a **final usage record** printed to the process's stdout/stderr
(which the spawning platform captures), regardless of how it stopped (guest shutdown, a
govern budget, `__shutdown__`, or a **`SIGTERM`** from the platform / process manager -
which is caught and drained through the same clean teardown, so a forced reclaim still
settles rather than dying silently; only `SIGKILL` skips the bill):

```
[nether] final usage (reason=shutdown): uptime_ms=... cpu_ms=... mem_peak_mb=... ram_mb=... cpus=... commands=... bytes_in=... bytes_out=... net_tx=... net_rx=... net_blocked=...
```

So a client never has to poll `__stats__` at exactly the right moment to bill a sandbox:
the platform always gets a complete, machine-readable accounting from the process output.

### Settlement mode (x402)

Settlement is a **toggle**, `x402` in `nether.conf` (default **off**), because general
(non-billable) workloads are the common case. It changes only the *framing* of the teardown
record - the metered fields, `__stats__`, the govern caps, and all observability are
identical whether it is on or off:

- **`x402=off`** (general workload): the teardown line is `[nether] final usage (reason=...)`
  - operational telemetry, **not** a billable settlement.
- **`x402=on`** (billable): the same line becomes `[nether] x402 settlement (reason=...)` -
  the record the payment layer settles against.

`__info__` advertises the mode (`x402=on|off`) so a client knows up front whether the
sandbox is billable, and the platform keys billing off the `x402 settlement` prefix (which
appears only in settlement mode). Flip it per sandbox; nothing else about the run changes.

## Govern knobs (set per sandbox in `nether.conf`)

`max_runtime_s` (wall-clock cap), `max_cpu_s` (CPU-time cap), `idle_timeout_s` (reclaim on
inactivity), `net_rate_kbps` (download cap), `max_output_bytes` (per-command output cap;
default 1 MiB), `net`/`net_open`/`net_allow`/`net_block` (egress firewall), `cpus`/`ram_mb`
(sizing). All are reported back by `__info__` so a client can verify what it got.

### Networking / egress (how to turn it on)

Networking is **off** unless `net=1`. With it on, the guest gets a configured `eth0`
(`10.0.2.15/24`, gateway `10.0.2.2`, DNS `10.0.2.3`) behind an in-VMM user-mode NAT
(slirp) - no host tap/bridge/root. Egress goes through a **default-deny-private** firewall:
public destinations are allowed; RFC-1918 private ranges, loopback, link-local, and the
`169.254.169.254` metadata address are blocked (SSRF-safe by default). Every new flow is
recorded in `__netlog__` with its `ALLOW`/`BLOCK` verdict.

```
net = 1                         # enable eth0 + slirp NAT (required)
# firewall is on by default (default-deny-private). To adjust:
net_open = 1                    # disable the firewall entirely (allow private too)
net_allow = 10.0.0.0/8, 192.168.0.0/16   # CIDR exceptions to the default-deny
net_block = 1.2.3.0/24          # additionally block these (e.g. a public range)
net_rate_kbps = 2000            # download bandwidth cap (0 = unlimited)
```

Verified live on HVF: with `net=1` (firewall on) a public host connects (`ALLOW`) while
`169.254.169.254` and `192.168.x.x` are refused (`BLOCK`); with `net_open=1` the firewall
is off and private destinations connect. `__info__` reports `net=` and `firewall=`.

## Snapshot / fork (HVF)

**Baking a base.** The platform pre-bakes a fork source by driving a control-mode sandbox
to a ready state (install deps, warm caches) and issuing **`__snapshot__ <path>`** - an
on-demand capture that quiesces the guest, writes the base, and resumes, all while the
sandbox stays driveable. This is the production path; the fixed-timer `snapshot_save=1`
mode is a demo. Because the base is captured *after* the sandbox is driven, its forks
inherit that warmed state (and, since it was control-mode, a live agent connection).

**Vetting a base.** Before relying on a stored base, run `nether` with
`validate_snapshot=<path>` in `nether.conf`: it checks the file against the current build
(format version, struct-layout fingerprints, section sizes vs the file length, and the
vsock engine state) and exits `0` with a one-line summary, or non-zero with a specific
message - **without booting anything**. So the platform can catch on-disk corruption, a
partial write, or version/layout drift after a Nether upgrade cheaply and mark a stale base
for re-baking, instead of discovering it on a failed restore.

A **snapshot-restored (forked)** sandbox is **driveable over the full control protocol**,
the same as a fresh boot - provided the **base snapshot was taken from a control-mode
sandbox** (booted with `control_socket=` so the vsock/agent channel exists). The restore
path then re-exposes the control socket, rebuilds the observe/meter/run `Core` fresh (each
fork is a new billable session, with its own teardown bill), and re-arms the govern
watchdogs from the fork's `nether.conf`.

The load-bearing property: the agent's vsock connection **survives the fork**. The snapshot
captures the vsock transport (virtio device) state, the host-side engine state (connection
table, listen registry, credit, staging ring), and the agent's connection id; the restore
re-wires the engine's callbacks to the new process and resumes that connection mid-stream.
So a driving command (a shell line, `__put__`/`__get__`) **round-trips immediately with no
reconnect** - there is no reconnect barrier for a client to wait on. A client drives a fork
exactly as it drives a fresh boot: connect → `__info__` → send commands.

What carries across: RAM (COW), per-vCPU state, GIC, console + virtio-blk, the disk;
when the base was control-mode, the vsock device + engine + agent connection; and when the
base ran with `net=1`, the virtio-net **device** (so the guest's NIC driver resumes
coherently). The slirp **NAT engine** does **not** carry across - it holds real host
sockets a forked process can't inherit, so the engine restarts fresh: in-flight outbound
flows reset and the guest re-establishes them at the TCP level (normal for a fork). The
fork's egress firewall / rate cap come from its own `nether.conf`, and `__stats__`/
`__netlog__` report the fork session's own egress. Gpu scanout state is not captured. A base
snapshot taken from a **non-control** sandbox has no vsock/agent state, so its forks are
console + virtio-blk only even if `control_socket=` is set; the restore logs an explicit
NOTE saying so. Snapshot-fork is HVF/aarch64 only (KVM snapshot is unimplemented). Fork
latency is ~90 ms (COW RAM map).
