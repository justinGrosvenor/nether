# Nether control protocol

The control socket is the integration contract between the platform (swerver) and a
running sandbox. The platform spawns one `nether` process per sandbox, points it at a
Unix-domain socket via `control_socket=<path>` in `nether.conf`, and drives the sandbox
over that socket. This is the stable surface to build against; everything else
(virtio devices, the in-guest agent, the boot path) is implementation detail.

The current version is **`proto_version=2`** (reported by `__info__`, and in `__help__`).
v2 frames *every* command/ack reply uniformly (see "Reply shapes"), which removes the v1
bare/framed ambiguity; it is a breaking wire change from v1, though a v1 client mostly still
works against a v2 server (see "Version compatibility"). Bump the version on any breaking
change to the command set or wire format. The command list is also discoverable at runtime
via `__help__`, so a client can self-check.

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

There are two categories, and which one a command uses is **fixed** - a client keys its read
loop off it. In v2 **every command/ack reply is framed**, so the common path is one loop with
no timing heuristic. It matches the reference client `tools/nether-ctl.c` `is_framed()`:

- **Framed** - ends with the agent's `0x1e<exit>\n` trailer. This is *every* command and ack:
  `__info__`/`__stats__`/`__help__`, **shell commands**, the acks `__shutdown__`/`__snapshot__`/
  `__put__`/`__get__`, **and every control-plane `ERR`/`OK`** (unknown command, read-only
  observer, agent-not-connected, too-many-clients, ...). Read until a raw `0x1e`, then the
  ASCII exit code (which may be negative), then `\n`. The exit code carries the outcome:

  | Exit | Meaning | Body |
  |---|---|---|
  | `0` | a report, an `OK` ack, or a shell command that exited 0 | report / `OK ...` / stdout |
  | `1..255` | a **shell command's** real exit code | command stdout+stderr |
  | `< 0` (`-1`) | a **control-plane error** (nether rejected/failed the command) | `ERR <reason>` |

  A POSIX exit is always `0..255`, so a negative code unambiguously flags a control-plane
  error with a single sign test - no timing, no string-matching. (The report/ack bodies are
  host-generated ASCII with no `0x1e`; shell output is delimiter-escaped by the in-guest agent
  so a raw `0x1e` only ever marks the trailer - see "Output framing" - and a `0x1e`/`0x1f` in a
  command is rejected fail-closed so an echoed argument can't forge a frame.)

- **Streamed (self-delimiting)** - no `0x1e` trailer; the reply is complete when the stream
  goes idle or the socket closes. A client reads these in a mode it chose for that command, so
  they are never subject to any framing ambiguity. Two sub-shapes:
  - **Logs / render** - `__events__`/`__cmdlog__`/`__netlog__` (a header line carries a
    count/cursor) and `__screen__`/`__screendiff__` (self-delimiting rendered rows). Do **not**
    wait for a `0x1e` on these.
  - **Binary** - `__frame__`/`__framediff__` write raw bytes (a PPM image / tile records) whose
    own header carries the dimensions; read to EOF/idle.
  - A streamed command that *cannot run* replies with a framed `ERR` line (per above),
    distinguishable from a real payload by its `ERR ` prefix (which no payload begins with).

### Version compatibility (v1 vs v2)

v1 sent the acks and every `ERR`/`OK` as a **bare** line with no `0x1e`, which forced a client
to distinguish a bare status from a framed reply with a timing heuristic (a ~500 ms settle) -
and that heuristic could truncate a framed reply whose output *began* `OK `/`ERR ` with a late
trailer. **v2 removes this entirely**: because the acks and errors are now framed, a v2 client
reads any command/ack reply by simply reading to the `0x1e` - no settle timer, no bare/framed
guard. A client that must interoperate with *both* server versions reads `proto_version` from
the `__info__` handshake (framed in both) and keeps the v1 settle path only for
`proto_version==1`; the reference client `tools/nether-ctl.c` does exactly this. A v1 client
talking to a v2 server also mostly works (the framed path is transparent; the acks pick up a
cosmetic trailing `0x1e0\n`), so rollout needs no lockstep. See
[control-protocol-v2.md](control-protocol-v2.md) for the full design and migration notes.

### Readiness

The socket accepts connections **before the guest finishes booting**. The host-intercepted
queries (`__info__`, `__stats__`, `__help__`) answer immediately. A *driving* command
(shell command, `__put__`/`__get__`) needs the in-guest agent, which connects partway
through boot, so an early command waits for it - bounded (default 30s). A guest that never
connects (a broken image) makes the command fail with `ERR agent not connected (guest not
ready)` rather than blocking forever. So a client can either just send its command (it
parks until the agent is up) or, to distinguish "booting" from "broken", treat that framed
control error (exit -1) as a fast failure.

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

### Output framing (a command's body cannot forge the trailer)

The `0x1e<exit>\n` trailer marks where a command's output ends. Command stdout is
untrusted (arbitrary workload bytes), so it **can** contain a literal `0x1e` - and a naive
"read until `0x1e`" would let a workload that prints `0x1e5\n` forge an early trailer,
desyncing the reader and every reply after it (finding **R2b**). Nether closes this at the
trusted framer: the in-guest agent **delimiter-escapes** the output body before it hits the
wire, so a raw `0x1e` appears **only** in the real trailer.

The escape (`tools/agent.c` `write_escaped` <-> `src/agent/control.zig` `outUnescape`):

- Delimiter `OUT_DELIM = 0x1e`; escape lead `OUT_ESC = 0x1f`.
- In the **body**, a `0x1e` or `0x1f` byte is emitted as `0x1f, (byte ^ 0x40)` - i.e. a
  printable `^` / `_`, never a raw `0x1e`. The trailer's `0x1e` is written raw.
- To recover the literal bytes, un-escape the body **after** framing on the raw `0x1e`: on
  a `0x1f`, the next byte XOR `0x40` is the original.

This makes the frame boundary **unforgeable by body content** for both nether's own
accounting (exit code, output cap, command audit) and the driving client. It is
**backward-safe**: a client that does not un-escape still frames correctly (the body never
contains a raw `0x1e`), and output with no `0x1e`/`0x1f` is byte-identical on the wire -
un-escaping is only needed for byte-perfect display of those two control bytes. Scope: this
defends against a hostile *workload* (the untrusted thing the agent runs). A compromised
*guest kernel* could write raw bytes to the vsock directly, but that is a VM-escape-class
threat contained by the hardware boundary (HVF/EPT), not by wire framing.

Binary or `0x1e`-bearing payloads that need exact fidelity without a client-side un-escape
should move over `__get__` (length-framed, binary-safe), not command stdout.

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
| `__screen__` | unframed | Terminal snapshot (scrollback + live grid), rendered server-side, self-delimiting (no `0x1e`). Requires control mode. |
| `__screendiff__` | unframed | Terminal rows changed since the last call (full screen on first call), self-delimiting. **Primary-only** (per-client diff state). |
| `__frame__` | binary | The virtio-gpu scanout as a binary PPM. Requires `gpu=1`. |
| `__framediff__` | binary | Framebuffer tiles changed since the last call. **Primary-only**. Requires `gpu=1`. |
| `__help__` | report | The command list (this table, abbreviated). |

### Primary client only (drive the sandbox)

| Command | Reply | Purpose |
|---|---|---|
| `__shutdown__` | framed `OK` | Clean teardown: the guest stops via its power-off path and the process exits (emitting the final usage bill). Reply `OK shutting down` + `0x1e0\n`. |
| `__snapshot__ [path]` | framed `OK`/`ERR` | Capture a fork-source base snapshot on demand (HVF only): quiesce the guest, write full machine state to `path` (default `nether.snap`, confined to the transfer jail), and resume - the sandbox keeps running. The reply (framed, exit 0 on `OK` / -1 on `ERR`) blocks until the file is on disk, so the platform knows the base is ready to fork. **Fails closed if the guest is not quiescent** (a vCPU not parked at WFI): a base captured mid-instruction can bake inconsistent state into every fork, so it returns `ERR` and resumes rather than write a dirty base. Set `snapshot_allow_dirty=1` in `nether.conf` to opt into best-effort capture. `ERR snapshot not supported on this backend` on KVM. |
| `__put__ <hostpath> <guestpath>` | framed `OK`/`ERR` | Push a host file into the guest. Bytes move over vsock with length framing (binary-safe). Host path is confined to the transfer jail. |
| `__get__ <guestpath> <hostpath>` | framed `OK`/`ERR` | Pull a guest file to the host. Same jail + framing. |
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
(sizing), `disk`/`disk_size_mb` (persistent disk; below), `app_port`/`data_socket`/
`max_data_conns` (data-plane proxy to an in-guest server; below). All caps are reported back
by `__info__` so a client can verify what it got.

### In-guest privilege drop (`run_as`)

By default the guest runs commands as **root** (the VM is the trust boundary, and many
workloads need root for `apk` / mounts). For untrusted code, defense-in-depth: set
`run_as=<user>` and the in-guest agent runs every command under that non-root user
(`fork` + `setgid`/`setuid` before exec, with `HOME`/`USER` set), so a guest-kernel escape
starts unprivileged. The image ships a `nether` user (uid 1000) with a writable home and
`/tmp`; a mounted persistent `/data` is world-writable. The policy travels on the kernel
cmdline (`nether.run_as=`), so a snapshot **fork inherits its base's `run_as`** (no DTB
rebuild on restore). Opt-in: unset = root, as before. Verified: `run_as=nether` runs as
uid 1000, can write `/tmp` and `~`, and is refused on `/etc`.

### Persistent disk

By default a sandbox is ephemeral (RAM-backed initramfs); all writes vanish on stop. For
stateful / database workloads, set `disk=<host-path>` (and optionally `disk_size_mb`,
default 64): Nether mmaps that host file (`MAP_SHARED`) as virtio-blk, so the guest's block
writes flush back to it and **survive sandbox restarts**. It is turnkey: when Nether
creates a brand-new disk file it tells the guest (`nether.disk_fresh=1` on the cmdline) and
`/init` runs `mkfs.ext4` once; then on every boot `/init` loads `virtio_blk` + `ext4` and
auto-mounts `/dev/vda` at `/data`, so a workload (even a non-root `run_as` one - `/data` is
world-writable) just uses `/data` with no setup. An existing disk is never reformatted.

`/data` is mounted **`-o sync`** for durability by default: data and metadata reach the
device synchronously and Nether's virtio-blk advertises `VIRTIO_BLK_F_FLUSH`, so a guest
`fsync` (or a sqlite commit, whose rollback journal needs durable directory ops) `msync`s
the host mapping to its file - the db survives a `__shutdown__`. A workload that prefers
write throughput over durability can `mount -o remount,relatime /data` and fsync itself.

The platform owns per-sandbox disk files: two live sandboxes must not share one (no
cross-mount locking). A file-backed disk is **not** captured in snapshots (the file is its
own persistence and can exceed the snapshot's disk section); set `disk=` on a fork's conf to
attach it (a fork does not re-run `/init`, so its disk must be pre-formatted). Verified: a
fresh `disk=` + `run_as=nether` runs a python+sqlite db on `/data` that survives a restart,
with no manual formatting or mounting.

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

### Data-plane proxy (reach a tenant's in-guest server)

For a long-lived tenant that runs its own server *inside* the VM (HTTP, worker, etc.),
Nether exposes it to the host as a concurrent upstream - so the platform proxies requests
to it instead of exec'ing a command per request. Two knobs:

```
app_port = 8080                 # the tenant's ORDINARY loopback TCP port inside the guest
data_socket = /run/nether/<id>.data.sock   # host Unix socket the platform proxies to
max_data_conns = 48             # optional cap on concurrent data-plane conns (<= 48)
data_idle_ms = 30000            # optional: reap a conn idle (both ways) this long (0 = off)
```

`app_port` makes `/init` start the in-guest forwarder (it bridges guest vsock:5001 to
`127.0.0.1:<app_port>`), so the tenant writes a **completely ordinary loopback TCP server -
no vsock awareness**. On the host, `data_socket` is an **owner-uid-gated** Unix listener;
each connection to it is spliced to a fresh host->guest vsock stream to the forwarder.

**Contract for a driving client (swerver):** treat `data_socket` as a proxy **upstream** -
open a connection per request (or pool), write the request bytes, read the response. It is a
**raw byte-stream** (no framing, no request-ids), so ordinary upstream/proxy machinery
applies directly. Up to `max_data_conns` concurrent conns per VM (default/cap 48). A slow or
wedged consumer cannot stall the guest: guest->host delivery is fully non-blocking with a
bounded per-conn window (256 KiB) and credit-on-delivery, so a wedged reader backpressures
the in-guest server (the guest stops sending) instead of blocking the vCPU - lossless, and
the vCPU never waits on the consumer. A slow or silent
guest server (accepts, then goes quiet) is reaped after `data_idle_ms` of two-way idleness,
so it cannot tie up a conn slot; the govern cap refuses excess conns (backpressure) rather
than unbounded fan-out. Data-plane traffic also counts as sandbox activity, so a VM busy
only with proxied requests is not idle-reclaimed. `__info__` reports `data_plane`,
`app_port`, `max_data_conns`, `data_idle_ms`; `__stats__` and the bill report `data_conns` +
`data_ms` (plus the shared `bytes_in`/`bytes_out`). A snapshot **fork inherits** `app_port`
(on the cmdline), so a warmed base with the tenant server already running forks into an
instantly-serving VM. Verified live on HVF: concurrent host connections reach an ordinary
`127.0.0.1:8080` guest server and back; the cap refuses excess; the meters advance.

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
coherently). The **data plane** carries too: the in-guest forwarder and the tenant's
own server live in guest RAM, so a fork inherits them already running. The host-side
`DataBridge` is not part of the snapshot (it holds a host listener a fork can't inherit),
so the restore path stands up a fresh one when the fork's `nether.conf` sets `data_socket`
- giving each fork its own data socket onto the *same* warm tenant server. So a base baked
with `app_port=` (forwarder running) and driven to start its server forks into an
**instantly-serving** upstream: the fork answers requests on its `data_socket` in tens of
milliseconds with no reboot and no server cold start. The slirp **NAT engine** does **not** carry across - it holds real host
sockets a forked process can't inherit, so the engine restarts fresh: in-flight outbound
flows reset and the guest re-establishes them at the TCP level (normal for a fork). The
fork's egress firewall / rate cap come from its own `nether.conf`, and `__stats__`/
`__netlog__` report the fork session's own egress. Gpu scanout state is not captured. A base
snapshot taken from a **non-control** sandbox has no vsock/agent state, so its forks are
console + virtio-blk only even if `control_socket=` is set; the restore logs an explicit
NOTE saying so. Snapshot-fork is HVF/aarch64 only (KVM snapshot is unimplemented). Fork
latency is ~90 ms (COW RAM map).
