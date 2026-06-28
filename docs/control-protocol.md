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
- **Errors** are a single `ERR <reason>\n` line.

### Reserved namespace

`__name__` is reserved for control commands. A line that starts with `__` but isn't a
recognized command (a typo, or a Tier-2 verb mistaken for a control command) is rejected
with `ERR unknown command ...` rather than forwarded to the guest. So a workload/agent
verb sent over this socket **must not** be `__`-prefixed: send a plain shell command (for
the stock guest agent) or your agent's own non-`__` verb. `__put__`/`__get__` are the only
`__` commands that take arguments.

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
| `__info__` | report | Static capabilities + limits: `proto_version`, backend, arch, cpus, ram_mb, net/firewall/gpu, and the govern caps (`max_runtime_s`, `max_cpu_s`, `idle_timeout_s`, `net_rate_kbps`, `max_output_bytes`). |
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
| `__put__ <hostpath> <guestpath>` | `OK`/`ERR` | Push a host file into the guest. Bytes move over vsock with length framing (binary-safe). Host path is confined to the transfer jail. |
| `__get__ <guestpath> <hostpath>` | `OK`/`ERR` | Pull a guest file to the host. Same jail + framing. |
| *(anything else)* | framed | Run the line as a shell command in the guest; output streams back, then `0x1e<exit>\n`. Metered as a command. |

## Lifecycle and settlement

Every session ends with a **final usage record** printed to the process's stdout/stderr
(which the spawning platform captures), regardless of how it stopped (guest shutdown, a
govern budget, `__shutdown__`, or client disconnect):

```
[nether] final usage (reason=shutdown): uptime_ms=... cpu_ms=... mem_peak_mb=... ram_mb=... cpus=... commands=... bytes_in=... bytes_out=... net_tx=... net_rx=... net_blocked=...
```

So a client never has to poll `__stats__` at exactly the right moment to bill a sandbox:
the platform always gets a complete, machine-readable accounting from the process output.

## Govern knobs (set per sandbox in `nether.conf`)

`max_runtime_s` (wall-clock cap), `max_cpu_s` (CPU-time cap), `idle_timeout_s` (reclaim on
inactivity), `net_rate_kbps` (download cap), `max_output_bytes` (per-command output cap),
`net`/`net_open`/`net_allow`/`net_block` (egress firewall), `cpus`/`ram_mb` (sizing). All
are reported back by `__info__` so a client can verify what it got.
