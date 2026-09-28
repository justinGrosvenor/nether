# Forking a running Linux VM

Nether can restore a warm Linux snapshot into a new VM process. The HVF proofs
also demonstrate a guest blocked on an outbound request continuing that request
after park and restore, with a separate host relay preserving the upstream.

## What a fork restores

A snapshot stores guest RAM and selected CPU, interrupt-controller, and device
state. Full snapshots map RAM with `MAP_PRIVATE` on restore. Pages are faulted
in as needed; the fork copies a page when it writes it. Metadata, VM creation,
device setup, and page faults still cost time.

Historical Apple Silicon results for a 512 MiB / 2-vCPU guest recorded roughly
0.5 seconds for a base boot, 10 ms to a driveable restored VM, and 25 ms to a
first response from a warm server. These are separate measurement boundaries,
not guarantees or current stack benchmarks. They were not rerun in the
2026-09-06 documentation audit.

HVF and KVM both implement full snapshot/COW restore, using different formats.
See [backend status](stack.md#backend-capabilities) and the
[KVM runbook](running-on-kvm.md#5-snapshot-and-fork).

## Capture and launch

Boot with a control socket, start the guest service, and establish readiness
before calling `__snapshot__ base.snap` through the primary control connection.
Capture paths are confined to the launch directory. `__snapshot__` writes a
base and resumes the original VM.

A new process selects restore mode in its working-directory `nether.conf`:

```ini
restore=1
restore_from=/absolute/path/base.snap
control_socket=/tmp/fork.control.sock
data_socket=/tmp/fork.data.sock
```

`restore_from` selects the file; **`restore=1` enables restoration**.
Supply the backend's matching CPU/device settings and external disk/network
configuration. A control-mode base is needed to restore its guest-agent channel;
an HTTP-serving base also needs its forwarder and application already running.

The first same-uid host control client becomes primary. The restored guest
channel and the host client connection are separate: a handshake alone does not
prove that the guest agent or application will respond.

## Mid-request park and wake: HVF

The vsock engine stores connection/credit state independently of host kernel
socket descriptors. That state and the guest's memory can survive a snapshot.
The real upstream TCP connection cannot be stored that way.

In the demonstrated composition:

1. A guest connects through its loopback egress forwarder and waits for a reply.
2. Nether dials the separate platform relay with
   `NETHER-EGRESS v1 conn=<id> resume=0`. The relay holds the real upstream.
3. `__park__` waits for the HVF quiescence and bridge-drain gates, captures,
   emits usage, and exits. The VMM process is gone; snapshot storage, mapped-file
   lifetime/page cache, and relay resources are not zero.
4. A fresh HVF process restores the park and reconnects surviving egress streams
   with `resume=1`. The relay supplies the waiting reply to the restored guest.

The guest resumes its blocked call without an application-level retry in this
scenario. Both backends reconnect surviving egress streams on restore; the
live park/wake proofs below exercise HVF. Ordinary virtio-net/slirp TCP flows
use a separate network path and are not preserved by this relay.

HVF captures the virtual counter so monotonic time can continue from the park
point. Its PL031 RTC reads current host time, but guest wall time needs
reconciliation such as `hwclock -s` after wake. VM Generation ID handling
triggers guest CRNG reseeding when the base and guest driver support it.

## Storage and lifecycle limits

HVF park-kind files are unlinked on resume. This consumes the pathname for
subsequent sequential launches; the caller must still serialize wake operations
and avoid copies or concurrent opens if it needs exactly one consumer. KVM has
no equivalent kind/unlink contract.

Snapshots do not capture GPU scanout state, mutable external services, or HVF
file-backed disk contents. A shared disk file remains shared even when RAM is
COW. Content-diff helpers exist, but control-driven diff capture is not wired;
see [snapshot storage](incremental-snapshot-spec.md).

## Reproduce the HVF scenario

Prepare the signed native binary and runtime image as described in
[reproducing](reproducing.md), then run:

```sh
python3 scripts/park_await_proof.py
python3 scripts/fork_serve.py
```

The first proof exercises two generations of mid-request park/wake using its
own relay. The second measures warm-fork serving.
