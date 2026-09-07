# Current stack and backend status

This page describes the source inspected on **2026-09-06**, including the local
KVM bridge and supervisor launch/readiness changes. It is a working-tree status,
not a claim that those changes are in a release.

## Process and ownership boundaries

```text
client -> Swerver gateway -> per-VM Unix data socket -> Nether -> guest HTTP service
              |
              +-- ensure <tenant> -> nether-supervisor -> launches Nether processes

browser -> swerver-console bridge -> Swerver admin API
                                 -> supervisor control + aggregate status
                                 -> per-VM Nether control sockets
```

| Component | Owns |
| --- | --- |
| Swerver gateway | Request routing, WASM filter execution, tenant-to-upstream registry |
| nether-supervisor | VM pool, base bake, process launch, ensure requests, reclaim |
| Nether | VM execution, guest devices, control/data bridges, snapshots, resource counters |
| Console bridge | API adapters, polling, VM attachment, SSE, in-memory settlement history |
| Console web app | Gateway, function, sandbox, metering, and demo views |

The gateway's tenant route and supervisor must agree on the socket directory.
The console discovers VM IDs from the gateway's tenant registry and socket names;
the supervisor status endpoint currently reports aggregate gauges, not a VM list.

The current stack uses separate processes. The exported Nether library and the
proposed event-loop integration do not establish a deployed single-process embed.

## Backend capabilities

| Capability | HVF / macOS aarch64 | KVM / Linux x86-64 |
| --- | --- | --- |
| Linux boot | ARM Image + initramfs | PVH vmlinux + initramfs |
| SMP, virtio-blk/net/rng/vsock | Implemented | Implemented |
| RAM sizing | `ram_mb`, minimum 256 MiB | Fixed 256 MiB in the current boot path |
| Control protocol and usage metering | Implemented | Implemented |
| slirp egress firewall | Implemented | Implemented |
| Full snapshot, COW restore, park | Implemented | Implemented |
| Snapshot format | NSNP v5 | NSKV v2 |
| Data and egress bridge wiring | Established HVF path | Present in the inspected local changes; live behavior not checked in this audit |
| Restore of established egress connections | HVF resume path and relay proofs | No equivalent resume call in the inspected KVM path |
| Park file consumed on resume | HVF park-kind lifecycle | No matching kind/unlink lifecycle in NSKV |
| Sparse/compressed base tooling and content-diff helpers | HVF format; see storage caveats below | No matching storage-tool integration |
| RTC/counter restore handling and rewind demo | HVF-specific implementation | Not equivalent |
| 2D virtio-gpu | Wired | Not wired |

There is no Linux/aarch64 backend in this tree. A Graviton deployment is not a
supported target merely because HVF uses an ARM guest.

Content-diff capture/restore helpers exist, but the control command parser does
not set `SnapCtx.diff_base`. Do not treat `__park__ base=...` as a supported
interface. See [snapshot storage](incremental-snapshot-spec.md).

## Operational limits

- Snapshot formats are backend-specific and contain build-sensitive state.
  Keep bases paired with their producing build and host environment; format
  validation is not a portability guarantee.
- HVF file-backed disks are reopened outside the snapshot. Forks using the same
  file share persistent storage; COW guest RAM does not make that disk private.
- The supervisor treats a nonempty `base_snap` as an instruction to bake a base
  at startup under `work_root/00000000/base.snap`. It falls back to cold boot
  if baking fails, and does not recover a persisted pool on restart.
- Supervisor idle age tracks ensure/readiness activity. Requests served through
  an existing gateway mapping do not refresh that age. Reclaim is not protected
  by a per-request VM lease.
- The console ledger is bounded and in memory. Its sandbox settlement entries
  use the last sampled stats; they are not a durable ledger or proof of payment.
- The console's SSE heartbeat describes bridge connection health. It does not
  prove that every upstream feed is fresh.

## Verification scope

Checks recorded during the 2026-09-06 review:

| Check | Result and limit |
| --- | --- |
| Nether host unit/fuzz-smoke suite | 262 tests passed |
| Nether native build | Passed with signing disabled in an isolated output prefix |
| Nether x86-64 Linux cross-build | Passed; compilation does not exercise KVM |
| Supervisor host suite | 46 tests passed |
| Console `pnpm test` | Passed: 43 bridge tests executed; 51 core tests reported from cache |
| Live VM boots, snapshot proofs, complete console stack | Not rerun in this review |

These counts describe that checkout and check run. Historical live results in
the runbooks and roadmap are not new measurements. The
[proof index](reproducing.md) explains which scripts exercise each behavior.
