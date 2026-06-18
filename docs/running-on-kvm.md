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
./scripts/config -e PVH -e SERIAL_8250 -e SERIAL_8250_CONSOLE -e BLK_DEV_INITRD -e ACPI
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

### Boot

```sh
# vmlinux and initramfs in the working directory are picked up automatically.
zig build run
```

Expected: kernel boot log over `ttyS0`, ending at a `/ #` shell prompt driven
entirely through Nether's serial. That is first light: a real OS under Nether.

## Notes

- The cmdline is `console=ttyS0 earlyprintk=ttyS0` (see main.zig). Guest RAM is
  256 MiB. The initramfs is placed near the top of low RAM.
- No block device yet, so the shell lives in the initramfs. virtio-blk for a real
  disk image is the next phase.
