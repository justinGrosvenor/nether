# Sandbox policy

nether is not only isolation. Each sandbox carries **runtime policy**: what it can reach on the network, how long it may run, and how much it may consume. This is the **govern** pillar on the edge runtime: structure, not policy documents.

## Enabling modes

Policy surfaces are opt-in per sandbox via `nether.conf` in the working directory (or legacy marker files). The platform writes one config per sandbox.

| Mode | Config key | Marker file | What it enables |
| --- | --- | --- | --- |
| **Control** | `control=1` or `control_socket=...` | `nether-control` | Unix socket, audit commands, `__shutdown__`, render |
| **Network** | `net=1` | `nether-net` | virtio-net + slirp NAT (default) or tap (see below) |
| **Vsock** | `vsock=1` | `nether-vsock` | Host↔guest channel (auto-on in control/agent mode) |

Setting `control_socket=/path/to.sock` enables control mode even without `control=1`. Default socket path when unset: `/tmp/nether.sock`.

Raw L2 tap (no egress firewall): add `net_tap=1` or touch `nether-net-tap`. Slirp + firewall is the default when only `net=1` is set.

## Egress firewall

When virtio-net uses the **slirp** backend (the default for `net=1`), an untrusted sandbox may reach the public internet but **not** the host LAN, loopback, link-local addresses, or cloud metadata (`169.254.169.254`). Tap mode (`net_tap=1`) bypasses the firewall.

| Verdict | Behavior |
| --- | --- |
| **ALLOW** | Connection proceeds through the in-VMM slirp NAT |
| **BLOCK (TCP)** | Fast RST ("connection refused") |
| **BLOCK (UDP)** | Datagram dropped |

Tunables in `nether.conf`:

```ini
net_open  = 1                 # disable firewall (trusted mode)
net_allow = 10.0.5.0/24,1.2.3.4/32   # exceptions to default-deny
net_block = 13.0.0.0/8        # deny otherwise-public destinations
net_rate_kbps = 4000          # download cap in kbps (0 = unlimited)
```

Denied attempts increment `net_blocked` in the `__stats__` report.

Slirp + firewall is implemented on **both** KVM and HVF when `net=1` is enabled. On KVM, virtio-net guest interface bring-up is still under investigation.

## Runtime budgets

| Axis | Config | Behavior |
| --- | --- | --- |
| **Wall clock** | `max_runtime_s` | Watchdog terminates the sandbox |
| **Idle** | `idle_timeout_s` | Reclaim when control-plane activity stops |
| **Bandwidth** | `net_rate_kbps` | Token-bucket on download; TCP backpressure when empty |
| **Output volume** | `max_output_bytes` | Per-command output cap (0 = unlimited) |

Watchdogs arm whenever `max_runtime_s` or `idle_timeout_s` is set, even outside control mode.

## Metering

The `__stats__` control command reports uptime, RAM, CPU count, byte counters, and network totals. Requires **control mode**. The platform (swerver + x402) reads these to settle per use.

```sh
printf '__stats__\n' | nc -U /tmp/nether.sock
```

## Audit

All audit commands require **control mode** and a running control socket.

| Command | Records |
| --- | --- |
| `__netlog__` | Last 256 egress destinations with ALLOW/BLOCK verdict (needs `net=1` + slirp) |
| `__cmdlog__` | Last 128 shell commands and exit codes |
| `__events__` | Unified chronological feed (commands, network, lifecycle) |

Full examples and formats are in [Running on HVF](../running-on-hvf.md#booting-linux-to-a-shell) (reference runbook; same protocol on KVM).

## Can't not won't

A sandbox **can't** reach host memory (EPT/IOMMU). With slirp and the firewall enabled it **can't** reach the metadata endpoint or your LAN. These are rules enforced in code, not terms of service.
