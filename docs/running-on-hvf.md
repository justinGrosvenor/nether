# Running Nether on Apple HVF (macOS / aarch64)

On an Apple Silicon Mac, Nether's HVF backend (Apple's Hypervisor.framework) runs
**aarch64** guests natively - no remote box, no Linux. This is the dev-host path;
the Linux/KVM/x86-64 path is in [running-on-kvm.md](running-on-kvm.md). The
backend is chosen at compile time from the host OS (see
[decisions.md](decisions.md) D9), so the same source tree builds either way.

## 0. Requirements

- Apple Silicon (M-series) Mac. HVF virtualizes the host architecture, so guests
  are aarch64 (not x86-64).
- The Command Line Tools SDK (for Hypervisor.framework and libSystem):
  `xcode-select --install` if needed.
- Zig 0.16.0 (see [running-on-kvm.md](running-on-kvm.md) step 1; the same pinned
  toolchain).

## 1. Build, sign, run

The HVF backend is selected automatically when the target is macOS. Build
natively, codesign with the hypervisor entitlement, then run:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools zig build -Dtarget=native
codesign --sign - --entitlements nether.entitlements --force zig-out/bin/nether
./zig-out/bin/nether
```

`com.apple.security.hypervisor` is a restricted entitlement, but **ad-hoc signing
(`--sign -`) works for running locally** - no paid Apple Developer account or
provisioning profile is needed on your own machine. Re-sign after every rebuild
(the binary's signature is replaced).

With no kernel present it runs a first-light blob (prints over the PL011 and
powers off via PSCI). With a kernel + rootfs in `kernels/` (below) it **boots
aarch64 Linux to an interactive shell**:

```
  Nether - aarch64 Linux on Apple Hypervisor.framework
  Linux 6.12.81-0-virt aarch64

~ # uname -a
Linux (none) 6.12.81-0-virt #1-Alpine SMP PREEMPT_DYNAMIC aarch64 Linux
```

## Booting Linux to a shell

Put an arm64 kernel `Image` and an initramfs under `kernels/` (gitignored). The
Alpine netboot kernel is EFI-zboot-wrapped, so extract the inner `Image`; the
rootfs is the Alpine aarch64 minirootfs repacked as a newc cpio with an `/init`.

```sh
mkdir -p kernels && cd kernels
A=https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64

# Kernel: fetch vmlinuz-virt and unwrap the EFI-zboot gzip payload to a raw Image.
curl -fSLO "$A/netboot/vmlinuz-virt"
off=$(($(od -An -tu4 -j8  -N4 vmlinuz-virt)))   # zboot payload_offset
len=$(($(od -An -tu4 -j12 -N4 vmlinuz-virt)))   # zboot payload_size
tail -c +$((off+1)) vmlinuz-virt | head -c "$len" | gunzip > Image

# Rootfs: Alpine aarch64 minirootfs + a tiny /init, packed as a newc cpio.gz.
curl -fSLO "$A/alpine-minirootfs-3.21.7-aarch64.tar.gz"
mkdir -p rootfs && tar -xzf alpine-minirootfs-3.21.7-aarch64.tar.gz -C rootfs
cat > rootfs/init <<'SH'
#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs dev /dev 2>/dev/null
echo; echo "  Nether - aarch64 Linux on Apple Hypervisor.framework"
echo "  $(uname -srm)"; echo
exec /bin/sh
SH
chmod +x rootfs/init
( cd rootfs && find . | cpio -o -H newc | gzip ) > initramfs.cpio.gz
cd ..
```

Then build, sign, and run (as in step 1). The boot loads `Image` at the RAM base,
the DTB at +128 MiB, and the initramfs at +192 MiB; it is interactive (type into
the shell). It powers off with `poweroff` (PSCI SYSTEM_OFF) or Ctrl-A is not
needed - exit by killing the process.

### Kernel + module-only leaf drivers (virtio-blk, vsock)

The `virt` kernel builds `virtio_pci` in but `virtio_blk`/`virtio_net`/`vsock`
etc. as modules, and the minirootfs ships none. The kernel image AND its modules
both live in the Alpine `linux-virt` apk, so pulling both from one apk guarantees
a vermagic match (don't mix versions). Current kernel: `6.12.93-0-virt`.

```sh
# one apk has /boot/vmlinuz-virt (EFI-zboot) and /lib/modules/<ver>/ (all modules)
V=6.12.93-r0; MV=6.12.93-0-virt
curl -fSLO "https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64/linux-virt-$V.apk"
mkdir -p lv && tar -xzf linux-virt-$V.apk -C lv 2>/dev/null
# unwrap the EFI-zboot kernel to a raw Image:
off=$(($(od -An -tu4 -j8  -N4 lv/boot/vmlinuz-virt)))
len=$(($(od -An -tu4 -j12 -N4 lv/boot/vmlinuz-virt)))
tail -c +$((off+1)) lv/boot/vmlinuz-virt | head -c "$len" | gunzip > kernels/Image
# install the WHOLE modules tree (with modules.dep) so the guest can `modprobe`
# by name and have deps resolved (virtio_net pulls net_failover+failover; the
# vsock transport pulls its common+core). The core virtio/virtio_pci/virtio_ring
# are built into the kernel; only the higher-level drivers are modules.
rm -rf rootfs/lib/modules && mkdir -p rootfs/lib/modules
cp -R lv/lib/modules/$MV rootfs/lib/modules/
# the persistent guest agent (exec-over-vsock) and the static vsock test client:
zig cc -target aarch64-linux-musl -static -O2 tools/agent.c        -o rootfs/agent
zig cc -target aarch64-linux-musl -static -O2 tools/vsock_client.c -o rootfs/vsock_client
( cd rootfs && find . | cpio -o -H newc --quiet | gzip -9 ) > kernels/initramfs.cpio.gz
```

`rootfs/init` then brings the sandbox up automatically on every boot: it
`modprobe`s `virtio_net` and `vmw_vsock_virtio_transport`, statically configures
the first non-loopback interface with the slirp plan (`10.0.2.15/24`, gw
`10.0.2.2`, DNS `10.0.2.3`), and starts `/agent`. So `net`, `vsock` and the agent
need no manual module loading; the `insmod` examples below are only for poking at
the datapaths by hand.

- **virtio-blk** (`0:2.0`, in-memory disk): `insmod /virtio_blk.ko` -> `/dev/vda`
  (2048 512-byte sectors); `head -c 26 /dev/vda` reads back the
  `NETHER-VIRTIO-BLK-DISK-OK` signature, proving the block datapath (request chain
  -> disk read -> DMA -> used ring -> MSI-X completion).
- **virtio-vsock** (`0:3.0`, opt-in via a `nether-vsock` marker): the host listens
  on port 1234 and echoes. In the guest, load the three modules in order then run
  the client:
  ```sh
  insmod /vsock.ko
  insmod /vmw_vsock_virtio_transport_common.ko
  insmod /vmw_vsock_virtio_transport.ko
  /vsock_client     # -> "VSOCK_ECHO: HELLO_FROM_GUEST_VSOCK"
  ```
  That round-trip (guest connects to host CID 2:1234, sends, host echoes back)
  exercises the full vsock datapath and is the host<->guest control channel.
- **Agent runtime** (opt-in via a `nether-agent` marker; the host listens on the
  agent port 5000): the sandbox becomes a REPL. `/init` auto-loads the vsock
  modules and starts the persistent guest agent (`tools/agent.c`), which connects
  to the host; then host stdin lines are sent as commands, run in the guest through
  `/bin/sh`, and their output is streamed back to host stdout. Build the agent like
  the vsock client and drop `agent` in the initramfs. Example:
  ```
  $ printf 'whoami\nuname -srm\nnproc\n' | ./zig-out/bin/nether   # (after boot)
  [agent] guest agent connected; type commands (they run in the sandbox)
  root
  Linux 6.12.93-0-virt aarch64
  4
  ```
  This is the in-sandbox exec primitive (run code in an isolated guest, collect
  results over the control channel - no network/ssh/shared FS). The PL011 console
  is output-only in this mode since host stdin drives the agent.
- **File push/pull** (over the control socket, host-mediated): get a task payload
  into the sandbox and artifacts back out. The operator sends text commands; the
  host moves the bytes over vsock with length framing (binary never crosses the
  line-oriented socket):
  ```sh
  printf '__put__ /host/task.tar /work/task.tar\n' | nc -U /tmp/sb.sock  # host -> guest
  printf '__get__ /work/out.bin /host/out.bin\n'   | nc -U /tmp/sb.sock  # guest -> host
  ```
  Each replies `OK <n> bytes -> <path>` or `ERR ...`. Proven byte-identical for
  1 B..8 MiB binary files (16 MiB cap). The guest agent handles `__PUT__`/`__GET__`
  on the same vsock connection as commands, so transfers interleave with exec.
- **Lifecycle** (over the control socket): `__stats__` returns the metering report;
  `__shutdown__` cleanly stops the sandbox on demand (acks `OK shutting down`, then
  the VM takes the PSCI-poweroff path and the process exits - not an abrupt kill).
  With `max_runtime_s` (a watchdog auto-stop) the platform has both ends of sandbox
  lifecycle.
  ```sh
  printf '__shutdown__\n' | nc -U /tmp/sb.sock   # -> OK shutting down; VM exits
  ```
- **Render** (over the control socket): `__screen__` returns a snapshot of the
  sandbox's terminal - the agent's command output rendered through a server-side VT
  screen (real CR/cursor/colors/clear, not log concatenation), so the platform can
  display the agent's visible work without the guest cooperating. Size it with
  `screen_rows` / `screen_cols` in nether.conf (default 24x80).
  ```sh
  printf '__screen__\n' | nc -U /tmp/sb.sock     # -> the rendered terminal text
  ```
  To *follow* the screen cheaply, `__screendiff__` returns only the live rows that
  changed since the last call (the first call, or a fresh client, gets the whole
  screen): `SCREEN <rows>x<cols>` then `<row-index> <text>` lines (empty text =
  cleared row), terminated by a blank line. Poll it on one connection to stream.
  ```sh
  printf '__screendiff__\n' | nc -U /tmp/sb.sock # -> changed rows since last diff
  ```
- **virtio-net** (`0:4.0`, opt-in via a `nether-net` marker) behind the in-VMM
  user-mode network stack (`slirp.zig`) - no host tap/bridge/root. Address plan
  10.0.2.0/24 (guest .15, gateway .2, DNS .3). Add the net modules
  (`virtio_net` needs `failover` + `net_failover`; DHCP needs `af_packet` for
  udhcpc's raw socket) and configure the interface:
  ```sh
  insmod /af_packet.ko; insmod /failover.ko; insmod /net_failover.ko; insmod /virtio_net.ko
  ip link set eth0 up
  udhcpc -i eth0 -q        # -> "lease of 10.0.2.15 obtained from 10.0.2.2"
  ping -c2 10.0.2.2        # -> 0% loss (ARP + ICMP via slirp)
  ```
  This exercises the virtio-net datapath (TX/RX over virtio-pci, MSI-X) plus the
  slirp ARP/IPv4/ICMP/UDP/DHCP handling.
  - **Outbound UDP + DNS** work through slirp's host-socket NAT (no privilege):
    ```sh
    nslookup example.com 10.0.2.3     # -> real records (forwarded to 8.8.8.8)
    ```
    A poll thread relays replies back to the guest.
  - **Outbound TCP** works through slirp's TCP NAT (guest connections bridged to
    host sockets) - real internet, no privilege:
    ```sh
    wget -O- http://example.com       # -> the actual page body
    ```
  - **Egress firewall** (govern): by default an untrusted sandbox may reach the
    public internet but not the host LAN, loopback, link-local, or cloud metadata
    (169.254.169.254). A blocked TCP connect is RST (fast "connection refused"); a
    blocked UDP datagram is dropped. Tunables in `nether.conf`:
    ```ini
    net_open  = 1                 # disable the firewall (trusted/open mode)
    net_allow = 10.0.5.0/24,1.2.3.4/32   # allow exceptions (override default-deny)
    net_block = 13.0.0.0/8        # deny otherwise-public destinations
    net_rate_kbps = 4000          # cap the download rate (kilobits/s; 0 = unlimited)
    ```
    ```sh
    wget -O- http://example.com   # allowed (public)
    wget http://192.168.1.2/      # -> "Connection refused" (RST from the firewall)
    ```
    Denied attempts are counted as `net_blocked` in the `__stats__` report.
  - **Bandwidth cap** (govern): `net_rate_kbps` token-bucket-limits the download
    (internet->guest) rate so an untrusted sandbox can't saturate the host uplink.
    When the bucket empties the poll loop stops reading host sockets and TCP
    backpressure slows the sender (lossless). Proven: a 4 MB fetch takes ~2 s
    uncapped, ~9 s at 4000 kbps (500 KB/s), ~17 s at 2000 kbps - proportional and
    matching the cap.

## How the Linux boot works

- `hv_vm_create` + `hv_vm_map` (guest RAM at the arm64 `virt` base `0x4000_0000`),
  `hv_vcpu_create`, the `hv_vcpu_run` loop, and the ESR_EL2 decode that turns a
  guest MMIO access into a `Bus` dispatch (the same device bus the x86 path uses).
- **GICv3** via the framework (`hv_gic`): distributor + redistributor + MSI
  region. The keystone is `MPIDR_EL1` - GICv3 affinity routing requires each
  vCPU's MPIDR set before the framework will associate (and MMIO-intercept) its
  redistributor. The redistributor *region* is ~32 MiB (max-vCPU sized), placed
  clear of the UART/RAM, and its base is queried from the framework into the DTB.
- **generic timer** (delivered via the GIC), **PSCI** over HVC for power, a
  **PL011** console (TX to stdout; RX from host stdin raising the PL011 SPI), and
  trapped system-register accesses emulated RAZ/WI.
- The DTB (`dtb.zig`) describes all of the above; the kernel gets its address in
  `X0` (the arm64 boot protocol).

## Notes

- Guest code/images are loaded through the host mapping, then
  `sys_icache_invalidate`d, since host data writes are not I-cache coherent with
  the guest core on Apple Silicon.
- `zig build run` is not wired for codesigning; run the signed binary directly.
  Cross-compiling the Linux artifact with `zig build` is unaffected and unsigned.
- Still to come (see [roadmap.md](roadmap.md)): virtio on aarch64 (reuse the
  device datapath; MSI via the GIC, whose region is already configured).
