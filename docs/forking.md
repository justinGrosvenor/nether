# Forking a running Linux VM

Here is a thing nether can do that I haven't seen anywhere else, so I want to
describe the mechanism precisely rather than sell it.

**You can send a request to a VM, snapshot the VM and kill it, and then answer the
request from a different VM that did not exist when the request arrived.**

The guest code doing the work is ordinary. A process inside the guest makes an
outbound call and blocks in `recv()` waiting for the reply. While it is blocked, the
whole VM is snapshotted and the process is killed. Nothing runs. Later, when the
reply is ready, a *fresh* VM is forked from that snapshot, and the original `recv()`
returns the reply bytes into ordinary code that slept through its own death. It never
learns it was moved.

That composition - park a blocked syscall across a VM's death, and complete it on a
fork - is the interesting part. The pieces underneath are simpler than they sound.

## A fork is a snapshot restore, and it's cheap

nether captures a running guest into a single file: CPU registers, device state, the
interrupt controller, and RAM. Restoring is not "boot from a snapshot" - it is
`fork()` for the whole machine. The important detail is how RAM comes back.

RAM is not read from the file. It is mapped copy-on-write (`mmap` `MAP_PRIVATE`) at
the snapshot's offset, so a restore does **not** pull 512 MB off disk. The fork shares
the base image's pages and only copies the pages it writes. That is the same
demand-paging basis Firecracker uses, and it is why a fork is cheap in both time and
memory:

- **Cold boot the base once: ~0.5 s** (kernel + userspace up, warm).
- **Fork it: ~10 ms** to a live, driveable VM.
- **~25 ms** to a first served request through a warm in-guest server.

Measured on Apple Silicon (HVF), a 512 MB / 2-vCPU guest. The ~10 ms is dominated by
`hv_vm_create` and restoring the interrupt-controller state - unavoidable hypervisor
setup, not data handling. The metadata read, disk, and vCPU rendezvous are each under
a millisecond. (These numbers are reproducible; see the bottom of this page. An
earlier version of the proof scripts polled readiness on a coarse timer and reported
~70 ms - that was the poll granularity, not the fork.)

So: one slow cold boot amortized over arbitrarily many cheap forks. That is the whole
economics of it.

## Why it isn't just "fast boot": the connection survives

Fast restore is table stakes. The reason nether can answer a request from a different
VM is that **the connection is part of the snapshot.**

The channel a guest uses to talk to the outside world is virtio-vsock, and nether's
vsock engine is a *pure in-memory state machine*: connection table, sequence numbers,
credit windows, staging ring - no host kernel sockets, no file descriptors. It is just
bytes in the guest's RAM and the VMM's heap. When you snapshot the VM, that state is
captured along with everything else. When you restore, it comes back exactly as it
was, mid-connection.

So a guest blocked in `recv()` on an open connection, snapshotted, carries that
connection into the snapshot file. The socket state on the guest side is frozen at the
exact point it was waiting.

The other half - the *real* upstream TCP socket to whatever the guest was calling - is
held by the host process outside the VM. When the guest makes an outbound call, an
in-guest forwarder bridges its ordinary loopback connection to a host-side Unix socket
(the "egress plane"); the host dials the real upstream and splices the two together.
That upstream socket is a normal host resource. It does not need the VM to exist.

## Parking, and waking

Put the two halves together and you get **park-while-awaiting-upstream**:

1. The guest sends an outbound request and blocks in `recv()`.
2. `__park__` quiesces the guest (fail-closed: it refuses if there are undelivered
   bytes in flight), captures the snapshot, bills the usage, and calls
   `exit(0)`. The VM is gone. Zero processes, zero RAM, zero CPU. The host keeps
   the upstream socket open.
3. The upstream reply arrives - seconds or minutes later. The host restores a fork
   from the park snapshot. The fork re-attaches the host side of the surviving
   connection (a one-line `resume=1` preamble tells the host to re-splice the parked
   upstream rather than dial fresh), and the guest's original `recv()` completes with
   the reply bytes.

Because the guest is captured mid-syscall and the connection state is captured with
it, the guest resumes *inside* the `recv()` it was in. There is no re-request, no
retry, no application-level checkpoint. The blocking call that slept through the VM's
death simply returns.

The clocks are handled honestly across the gap: the guest's monotonic clock stays
continuous (the virtual counter is captured and rebased so an armed timer fires with
its remaining duration), while the wall clock catches up to real time on resume. And
each fork reseeds its CRNG, so two forks of the same base do not share a random stream.

Wake to reply-delivered is **~20 ms**.

## Reproduce it

Everything above is a live proof, not a diagram. On an Apple Silicon Mac:

```sh
zig build -Dtarget=native
codesign --sign - --entitlements nether.entitlements --force zig-out/bin/nether
./scripts/fetch-guest-image.sh          # build a bootable aarch64 Linux guest
python3 scripts/park_await_proof.py      # the mid-request park/wake, end to end
```

`park_await_proof.py` boots a base, drives a guest to block in `recv()` on an outbound
request, `__park__`s it (killing the VM), holds the upstream, then forks a VM that
completes the *same* `recv()` with the reply - and does it a second time to show the
woken fork can itself re-park. `scripts/fork_serve.py` shows the raw fork-to-serving
path; `scripts/reproducing.md` indexes the rest.

## What this is, and isn't

- **Backend:** Apple Hypervisor.framework, aarch64, macOS only. The x86/KVM backend
  is a reference implementation and does not do snapshot-fork yet.
- **Maturity:** pre-1.0, no external security audit. The guest is treated as hostile
  (malformed guest input is the primary threat model, the guest-facing parsers are
  continuously fuzzed), but don't run untrusted guests in production yet.
- **Novelty:** snapshot-restore-as-fork is well-trodden (Firecracker, and the
  FaaSnap/REAP line of research on fast serving). What I haven't seen elsewhere is
  parking a *blocked syscall* across a VM's death and completing it on a fork - the
  connection surviving the snapshot is what makes that work. If someone else does
  this, I'd genuinely like to read how.

The code is Zig, from scratch, in the open: [github.com/justinGrosvenor/nether](https://github.com/justinGrosvenor/nether).
