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
# add the leaf modules (modules are gzipped .ko.gz; insmod needs them decompressed)
M=lv/lib/modules/$MV/kernel
for ko in drivers/block/virtio_blk net/vmw_vsock/vsock \
          net/vmw_vsock/vmw_vsock_virtio_transport_common \
          net/vmw_vsock/vmw_vsock_virtio_transport; do
  gunzip -c "$M/$ko.ko.gz" > "rootfs/$(basename $ko).ko"
done
# the static vsock client (busybox has no vsock tool):
zig cc -target aarch64-linux-musl -static -O2 tools/vsock_client.c -o rootfs/vsock_client
( cd rootfs && find . | cpio -o -H newc --quiet | gzip ) > kernels/initramfs.cpio.gz
```

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
  slirp ARP/IPv4/ICMP/UDP/DHCP handling. Outbound NAT to real host sockets
  (UDP/DNS, TCP) is the next step on top of this.

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
