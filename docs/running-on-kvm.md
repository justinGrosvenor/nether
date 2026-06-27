# Running Nether on a KVM host

Nether can only *run* on Linux x86_64 with hardware virtualization. This is the
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
  -e VSOCKETS -e VIRTIO_VSOCKETS
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
above. It cross-compiles the agent, fetches busybox, and writes an `/init` that
configures `eth0` to the slirp plan and starts the agent:

```sh
./tools/build-guest-x86.sh        # -> kernels/initramfs-x86.cpio.gz
cp kernels/initramfs-x86.cpio.gz initramfs
```

This needs the kernel built with the platform stack (the `VIRTIO_NET`/`VIRTIO_CONSOLE`
/`VSOCKETS`/`VIRTIO_VSOCKETS` options above). Then launch with a `nether.conf`:

```
control_socket=/tmp/nether.sock
vsock=1
net=1
```

and attach with `nc -U /tmp/nether.sock` (the same control protocol as HVF:
`__info__`, `__stats__`, `__events__`, `__shutdown__`, command relay, `__put__`/
`__get__`). NOTE: the KVM platform layer is compile-verified but not yet run on
metal - this is the day-one verification path.

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
  console grid over HTTP on port 9000 (the guest's serial output, rendered to
  HTML, polled by the page). Browse `http://<box-ip>:9000` (open the port / use an
  SSH tunnel). It is interactive: keystrokes in the page are mapped to terminal
  byte sequences and POSTed to the guest's serial RX. Without the marker, no port
  is bound.
- **virtio-vsock**: `touch nether-vsock` before `zig build run` to present a
  vsock device (PCI 0:2.0, guest CID 3) with a host echo service on port 1234.
  The guest kernel needs `CONFIG_VSOCKETS` + `CONFIG_VIRTIO_VSOCKETS`. From the
  guest shell, connect to the host (CID 2) and confirm the echo:
  ```sh
  # guest: needs a vsock-aware tool (socat with VSOCK, or a few lines of python)
  socat - VSOCK-CONNECT:2:1234     # type a line; it comes straight back
  ```
  This is the spine for the swerver<->guest channel; the echo is a placeholder
  for the real listener.
- **virtio-net**: `touch nether-net` before `zig build run` to present a
  tap-backed NIC (PCI 0:3.0, MAC 52:54:00:12:34:56). The guest kernel needs the
  virtio-net driver (`-e VIRTIO_NET` in the config recipe above). The host must
  provide a configured `tap0` first:
  ```sh
  # host (run once, as root): create the tap and give it an address
  ip tuntap add dev tap0 mode tap
  ip addr add 10.0.0.1/24 dev tap0
  ip link set tap0 up
  # for outbound internet, also enable forwarding + NAT to your uplink:
  sysctl -w net.ipv4.ip_forward=1
  iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
  ```
  Then in the guest, bring the interface up and confirm the link:
  ```sh
  # guest shell:
  ip addr add 10.0.0.2/24 dev eth0
  ip link set eth0 up
  ping -c1 10.0.0.1        # reaches the host tap
  ```
  Frames flow guest TX -> tap write, and a host reader thread feeds tap reads
  into the guest RX. No offloads are negotiated, so frames are plain (MTU 1500).
