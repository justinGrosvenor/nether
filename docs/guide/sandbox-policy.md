# Sandbox policy

nether is not only isolation. Each sandbox carries **runtime policy**: what it can reach on the network, how long it may run, and how much it may consume. This is the **govern** pillar on the edge runtime: structure, not policy documents.

## Egress firewall

By default an untrusted sandbox may reach the public internet but **not** the host LAN, loopback, link-local addresses, or cloud metadata (`169.254.169.254`).

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

## Runtime budgets

| Axis | Config | Behavior |
| --- | --- | --- |
| **Wall clock** | `max_runtime_s` | Watchdog terminates the sandbox |
| **Idle** | `idle_timeout_s` | Reclaim when control-plane activity stops |
| **Bandwidth** | `net_rate_kbps` | Token-bucket on download; TCP backpressure when empty |
| **Output volume** | control-plane caps | Bounds command and agent output volume |

## Metering

The `__stats__` control command reports uptime, RAM, CPU count, byte counters, and network totals. The platform (swerver + x402) reads these to settle per use.

```sh
printf '__stats__\n' | nc -U /tmp/sb.sock
```

## Audit

| Command | Records |
| --- | --- |
| `__netlog__` | Last 256 egress destinations with ALLOW/BLOCK verdict |
| `__cmdlog__` | Last 128 shell commands and exit codes |
| `__events__` | Unified chronological feed (commands, network, lifecycle) |

Full examples and formats are in [Running on HVF](../running-on-hvf.md#booting-linux-to-a-shell) (the platform track landed on HVF first).

## Can't not won't

A sandbox **can't** reach host memory (EPT/IOMMU). With the firewall enabled it **can't** reach the metadata endpoint or your LAN. These are rules enforced in code, not terms of service.

See [Platform thesis](../thesis.md) for how govern and isolate fit the edge runtime.