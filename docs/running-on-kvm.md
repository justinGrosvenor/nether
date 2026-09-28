# Running Nether on a KVM host

Nether's KVM backend runs on Linux x86-64 with hardware virtualization. This is the
turnkey path from a fresh box to a live boot. AWS needs a bare-metal instance;
GCP and Azure expose nested virtualization on ordinary VMs (cheaper, no metal).

## 0. Verify the host can do KVM

```sh
ls -l /dev/kvm                      # must exist
grep -Eo 'vmx|svm' /proc/cpuinfo | head -1   # vmx (Intel) or svm (AMD)
```

If `/dev/kvm` is missing on a cloud VM, nested virt is not enabled (AWS: use a
`*.metal` instance; GCP: `--enable-nested-virtualization`; Azure: a v3+ family).

## 1. Install Zig 0.16.0

```sh
curl -fSL https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz -o zig.tar.xz
mkdir -p zig && tar -xf zig.tar.xz -C zig --strip-components=1
export PATH="$PWD/zig:$PATH"
zig version   # 0.16.0
```

## 2. Build and run the test suite

```sh
zig build test     # ABI, memory map, device, ACPI, ELF, PVH unit tests
zig build run      # no vmlinux present -> real-mode smoke test under real KVM
```

Expected smoke-test output, which validates the whole substrate (KVM_RUN loop,
memory, exit dispatch, serial, ACPI S5) on hardware:

```
Nether lives. Phase 0: real-mode guest over COM1.
[nether] guest shutdown.
```

## 3. PVH Linux boot

Nether's loader takes a PVH-capable ELF `vmlinux` (not a distro `bzImage`). Build
a small one with the PVH entry, plus a busybox initramfs.

### Kernel (CONFIG_PVH)

```sh
# build deps (AL2023/Fedora): dnf install -y gcc make flex bison bc elfutils-libelf-devel openssl-devel perl ncurses-devel xz
curl -fSL https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.tar.xz -o linux.tar.xz
tar -xf linux.tar.xz && cd linux-6.12
make x86_64_defconfig
# PVH + serial console + initramfs + devtmpfs, and the virtio-pci/MSI stack the
# virtio-blk path needs. Missing any of the virtio/PCI options boots fine but
# leaves no /dev/vda.
./scripts/config -e PVH \
  -e SERIAL_8250 -e SERIAL_8250_CONSOLE \
  -e BLK_DEV_INITRD -e DEVTMPFS -e DEVTMPFS_MOUNT \
  -e ACPI -e KVM_GUEST -e PARAVIRT \
  -e PCI -e PCI_MSI -e VIRTIO -e VIRTIO_PCI -e VIRTIO_BLK \
  -e VIRTIO_NET -e VIRTIO_CONSOLE \
  -e VSOCKETS -e VIRTIO_VSOCKETS \
  -e VIRT_DRIVERS -e VMGENID
make olddefconfig
make -j"$(nproc)"            # vmlinux (ELF, with the PVH note) lands in the build root
cp vmlinux ../vmlinux && cd ..
```

### initramfs (busybox)

```sh
curl -fSL https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox -o busybox
chmod +x busybox
mkdir -p initrd/bin && cp busybox initrd/bin/
cat > initrd/init <<'SH'
#!/bin/busybox sh
/bin/busybox --install -s /bin
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sys /sys 2>/dev/null
echo "=== nether: initramfs userspace reached ==="
exec /bin/sh
SH
chmod +x initrd/init
( cd initrd && find . | cpio -o -H newc | gzip ) > initramfs
```

### initramfs (agent / platform)

For the full platform path (control socket, agent REPL, metering, observe, govern,
render - the same surfaces as HVF), use the build script instead of the bare shell
above. It cross-compiles the agent and TCP/vsock forwarder. Its `/init` brings up
loopback even when `net=0`, configures an available NIC for slirp, starts the
agent, and starts the forwarder when `app_port` or `egress_port` is configured:

```sh
./tools/build-guest-x86.sh --minimal # static BusyBox + agent + forwarder
# For the supervisor demo (Python), or Python/SQLite/Node workloads:
./tools/build-guest-x86.sh --runtimes # requires Docker; builds linux/amd64
cp kernels/initramfs-x86.cpio.gz initramfs
```

`--runtimes` defaults to `RUNTIMES="python3 sqlite nodejs e2fsprogs"`; override that
package list as needed. `OUT=/path` changes the output directory. This image was
built and its runtimes executed under Docker on 2026-09-06; that is not a KVM boot
result. For supervisor launches, put `vmlinux` and the image renamed to `initramfs`
in `kernels_dir`. The supervisor checks both are readable, nonempty regular files
before spawning; it does not validate kernel configuration or guest service readiness
at that stage. The minimal image has no Python.
For an offline minimal build, `BUSYBOX_X86=/path/to/static-x86_64-busybox`
uses an existing binary instead of downloading it.

This needs the kernel built with the platform stack (the `VIRTIO_NET`/`VIRTIO_CONSOLE`
/`VSOCKETS`/`VIRTIO_VSOCKETS` options above). Then launch with a `nether.conf`:

```
control_socket=/tmp/nether.sock
vsock=1
net=1
```

and attach with `nc -U /tmp/nether.sock` (the same control protocol as HVF:
`__info__`, `__stats__`, `__events__`, `__shutdown__`, command relay, `__put__`/
`__get__`). **Verified on metal** (`c5.metal`, 2026-07-23): PVH boot, shell, control
plane over vsock, `__shutdown__`, watchdogs, virtio-net (`eth0` up, DNS/HTTP/HTTPS
through the slirp NAT + egress firewall), and SMP (`cpus=4`) all pass. The status
header in the [roadmap](roadmap.md) tracks what remains (GPU).

### Boot

```sh
# vmlinux and initramfs in the working directory are picked up automatically.
zig build run
```

Expected: kernel boot log over `ttyS0`, ending at a `/ #` shell prompt driven
entirely through Nether's serial, and interactive (type into the shell). That is
first light: a real OS under Nether.

## 4. virtio-blk disk

If a `disk.img` is present in the working directory, Nether presents it as
`/dev/vda` (PCI 0:1.0, MSI-X completions). Create one and confirm it from the
guest shell:

```sh
# host: a 16 MiB image with a recognizable marker at the front
dd if=/dev/zero of=disk.img bs=1M count=16
printf 'NETHER-DISK' | dd of=disk.img conv=notrunc
zig build run        # vmlinux + initramfs + disk.img all picked up automatically
```

```sh
# guest shell:
head -c 11 /dev/vda            # -> NETHER-DISK  (read path)
echo hello | dd of=/dev/vda bs=512 seek=1   # write path
# back on the host, the bytes are visible in disk.img (writes are shared mmap)
```

## 5. Snapshot and fork

The KVM backend has the same cross-process fork primitive as HVF. A running guest is
captured to an image: every vCPU's state via `KVM_GET_*` (regs, sregs, MSRs,
xsave/xcrs, LAPIC, mp_state, pending events), the kvmclock, the IOAPIC table, the
virtio transport state for blk/net/vsock plus the vsock engine and the live agent
connection, and sparse guest RAM. A fresh process re-creates it with guest RAM
`MAP_PRIVATE`-mapped straight from the image, so a fork shares the base's pages and
copies only what it writes.

**Timed capture (demo).** `snapshot=1` in `nether.conf` arms a thread that, after
`snapshot_after_s` seconds (default 8), quiesces the guest, writes `snapshot_path`
(default `nether.snap`), and exits. The image is the guest.

**On-demand capture.** With a control socket configured, `__snapshot__
[path]` captures a base and resumes the guest; `__park__ [path]` captures, bills, and
exits. These commands use the shared [control protocol](control-protocol.md),
with backend-specific capture behavior.

**Restore / fork.** In a working directory with the same device set as the base
(`vsock`, `net`, `cpus`, and whether `disk.img` is present):

```
restore=1
restore_from=nether.snap
```

The restored guest resumes where it was captured with its agent connection intact, so
the control path can reattach without a new guest-side connection. Earlier
bare-metal notes recorded about 150 ms to a live control socket; this was not
remeasured in the 2026-09-06 source audit. Two forks of one base get distinct VM Generation IDs: on restore
nether writes a fresh GUID into the fork's private page and pulses GPE0/SCI, the
guest's stock `vmgenid` driver reseeds the CRNG (`random: crng reseeded due to
virtual machine fork`), and sibling forks draw different random streams from their
first read. `fork_reseed=0` opts out. The guest kernel needs `CONFIG_VIRT_DRIVERS` +
`CONFIG_VMGENID` (already in the recipe above).

Constraints: retain the same host/build environment (native-endian, KVM format
`NSKV` v2, not
interchangeable with HVF images); the fork must launch with the same vCPU count and
device set as the base; the slirp NAT engine restarts fresh (in-flight outbound flows
reset, as on HVF). HVF storage tools do not apply to NSKV. KVM park files do
not carry the HVF one-shot kind/unlink contract. A failed KVM park can leave
vCPUs paused; callers must not assume every capture error resumes execution.

The KVM boot path wires data/egress bridges and reconnects established egress
connections before resuming vCPUs. Both backends use the same helper, which sends
`NETHER-EGRESS v1 conn=<id> resume=1` to the relay. Host socket regression tests and
the x86-64 Linux build pass. Live KVM park/restore remains unverified in this
update; the HVF park proof also checks a one-shot file lifecycle that KVM lacks.

## Notes

- The cmdline (see `main.zig`) is
  `console=ttyS0,115200 earlyprintk=serial,ttyS0,115200 nokaslr no_timer_check`.
  `no_timer_check` is required once the userspace IOAPIC exists but there is no
  i8254 PIT, or the kernel panics in its IO-APIC+timer routing check. Guest RAM
  is 256 MiB; the initramfs is placed near the top of low RAM.
- The host terminal is put in raw mode for an interactive console; it is restored
  on exit. With raw mode, Ctrl-C reaches the guest, so exit Nether by powering off
  the guest (a SIGKILL would leave the terminal raw; recover with `reset`).
- Full bring-up gotchas (segment limits, CPUID, PVH magic, the 16-byte serial
  stall, IOAPIC, ACPI) are in [bringup-notes.md](bringup-notes.md).
- **Web console**: `touch nether-web` before `zig build run` to serve the live
  console grid over HTTP on port 9000. Use the tokenized loopback URL printed
  by Nether, or an SSH tunnel to that listener. The page renders the guest's
  serial output. Without the marker, no port is bound.
- **virtio-vsock**: `touch nether-vsock` before `zig build run` to present a
  vsock device (PCI 0:2.0, guest CID 3) with a host echo service on port 1234.
  The guest kernel needs `CONFIG_VSOCKETS` + `CONFIG_VIRTIO_VSOCKETS`. From the
  guest shell, connect to the host (CID 2) and confirm the echo:
  ```sh
  # guest: needs a vsock-aware tool (socat with VSOCK, or a few lines of python)
  socat - VSOCK-CONNECT:2:1234     # type a line; it comes straight back
  ```
  Echo is a standalone smoke service. Control mode also enables the real guest
  agent listener and the shared control protocol.
- **virtio-net**: enable with `net=1` in `nether.conf` or `touch nether-net`
  before launch. Presents PCI 0:3.0 (MAC 52:54:00:12:34:56). The guest kernel
  needs the virtio-net driver (`-e VIRTIO_NET` in the config recipe above).
  - **Default (slirp):** in-VMM user-mode NAT with the egress firewall — same as
    HVF. No host tap or root. Address plan 10.0.2.0/24 (guest .15, gateway .2,
    DNS .3). Tunables: `net_open`, `net_allow`, `net_block`, `net_rate_kbps` in
    `nether.conf`. Earlier bare-metal notes record a working guest interface;
    the old enumeration-only bring-up issue is no longer the stated backend
    status. Configure the guest interface in `/init` for the image you build.
  - **Optional (tap):** `net_tap=1` or `touch nether-net-tap` for raw L2 on `tap0`
    (no egress firewall). The host must pre-create and configure `tap0`:
    ```sh
    # host (run once, as root):
    ip tuntap add dev tap0 mode tap
    ip addr add 10.0.0.1/24 dev tap0
    ip link set tap0 up
    ```
    Guest: `ip addr add 10.0.0.2/24 dev eth0 && ip link set eth0 up`.
