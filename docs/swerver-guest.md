# A fresh Nether VM per request, with Swerver inside

This example turns the public HttpArena Swerver application into a warm Nether
guest. A host Swerver gateway reads `x-tenant`, asks `nether-supervisor` to
ensure that tenant, and proxies the request to the fresh VM's Unix data socket.
Use a unique tenant value for every request to get one copy-on-write VM per
request; reuse the value to hit the already-warm VM.

The supervisor can remain private. The build helper copies its already-built
binary into the gitignored output directory, while the public Nether and gateway
only depend on its small Unix-socket protocol (`ensure <tenant>` returns a
data-socket path). Neither its source nor its binary is committed to this repo or
baked into the guest.

## Build the exact stack

The helper assumes sibling checkouts of `nether`, `swerver`, and `HttpArena`.
Override `SWERVER_ROOT`, `HTTPARENA_ROOT`, or `ZIG` if yours differ.

```sh
cd ~/nether
./scripts/fetch-guest-image.sh

zig build -Dtarget=native -Doptimize=ReleaseFast
codesign --sign - --entitlements nether.entitlements \
  --generate-entitlement-der --force zig-out/bin/nether

cd ~/nether-supervisor
zig build -Doptimize=ReleaseFast

cd ~/swerver
zig build -Doptimize=ReleaseFast -Denable-proxy=true -Denable-wasm=true

cd ~/nether
ZIG=~/Library/zig/0.16.0/zig ./scripts/build-swerver-guest.sh
```

`build-swerver-guest.sh` exports committed source from both repositories,
cross-compiles the HttpArena application as a static aarch64 Linux binary,
adds it to the pinned Alpine initramfs, and starts it from `/init` before the
base snapshot is taken. It writes the image and aligned runtime configuration
under `kernels/swerver/` (gitignored), plus `build-info.txt` with the source
commits and artifact hashes. If the private supervisor checkout is elsewhere,
set `NETHER_SUPERVISOR_BIN=/absolute/path/to/nether-supervisor`; the helper
vendors that binary locally into the same gitignored output directory.

## Run it on Apple Silicon

The paths are deliberately short because macOS Unix sockets have a small path
limit. Remove a previous stopped run, then launch the supervisor from the
directory containing its generated configuration:

```sh
rm -rf /tmp/nsw
mkdir -p /tmp/nsw/run
cp ~/nether/kernels/swerver/nether-supervisor.conf /tmp/nsw/run/

cd /tmp/nsw/run
~/nether/kernels/swerver/nether-supervisor \
  > /tmp/nsw/supervisor.log 2>&1 &

# Wait for the base bake. The control socket appears only after the warm base
# has answered a real HTTP readiness request and its snapshot is on disk.
while [ ! -S /tmp/nsw/control.sock ]; do sleep 0.1; done

cd ~/swerver
./zig-out/bin/swerver --config ~/nether/kernels/swerver/gateway.json \
  > /tmp/nsw/gateway.log 2>&1 &
```

Drive the full gateway route. The rewrite removes `/tenant`, so the guest sees
the HttpArena `/baseline11` route directly:

```sh
curl -H "x-tenant: one-$(date +%s)" \
  'http://127.0.0.1:18080/tenant/baseline11?a=25&b=17'
# 42
```

For a synchronized burst, the stdlib-only probe talks to the supervisor and
then the returned data sockets directly. That isolates the measured interval
to supervisor dispatch + HVF restore + the guest's first Swerver response:

```sh
cd ~/nether
python3 scripts/swerver_guest_burst.py --concurrency 8
python3 scripts/swerver_guest_burst.py --concurrency 16
```

This is a warm-fork measurement, not a cold Linux boot and not an HttpArena
throughput score. Each request uses a unique tenant, so each result includes a
new VM restore and its first real application response.

## Linux and EC2 Spot

The example currently exercises Nether's developed Apple HVF/aarch64 path.
An EC2 bare-metal Spot worker needs the KVM/x86-64 backend brought to feature
parity for snapshot restore, data sockets, and the supervisor lifecycle before
the same flow can run there. Keep cloud provisioning outside the request path:
acquire Spot capacity, build/sign or fetch the host artifacts, bake one base,
then accept requests. A Spot interruption should drain the gateway and discard
the host; every tenant VM is disposable by design.
