# Nether bring-up notes (hard-won, verified on bare-metal KVM)

Field notes from taking Nether from a `KVM_RUN` skeleton to a Linux 6.12 guest
that boots to an interactive shell with working virtio-blk, on a real KVM host.
Almost every item here cost a live debug cycle to find. Keep this current.

## KVM / x86 VMM gotchas (the expensive ones)

1. **VMCS segment limit is byte-granular, not the 20-bit descriptor value.** A
   flat 4 GiB segment needs `kvm_segment.limit = 0xFFFFFFFF`, NOT `0xFFFFF`. KVM
   does not re-expand the limit by the G bit. With `0xFFFFF` you get a literal
   1 MiB limit; a kernel loaded at 16 MiB faults on the first instruction fetch
   (#GP -> triple fault, RIP stuck at entry).

2. **CPUID must be programmed** (`KVM_GET_SUPPORTED_CPUID` -> `KVM_SET_CPUID2`).
   Without it the guest sees no long-mode bit and the kernel's `EFER.LME` `wrmsr`
   #GPs in early head_64.S.

3. **GET_SUPPORTED_CPUID leaks the host core's APIC ID.** Rewrite leaf 1
   EBX[31:24] and leaf 0xB/0x1F EDX to the vCPU id. Otherwise the guest aims MSIs
   at the host's APIC id (e.g. 8) while the vCPU LAPIC is id 0, and every MSI is
   silently dropped (`KVM_SIGNAL_MSI` returns 0). Symptom: device "works" but
   completions never arrive. Watch for `[Firmware Bug]: APIC ID mismatch` in dmesg.

4. **PVH magic is `0x336ec578`** (`XEN_HVM_START_MAGIC_VALUE`). Wrong value trips
   `xen_prepare_pvh()`'s `BUG()` (`ud2` -> triple fault, no IDT yet).

5. **PVH entry state**: 32-bit protected mode, paging off, flat CS/DS/ES/SS/FS/GS,
   `EBX` = hvm_start_info paddr, GDT set. The kernel builds its own GDT, page
   tables, and enters long mode itself. Boot a PVH ELF `vmlinux` (has the
   `XEN_ELFNOTE_PHYS32_ENTRY` note, readelf -n type 0x12), NOT a bzImage.

6. **Split irqchip (KVM_CAP_SPLIT_IRQCHIP) puts the IOAPIC/PIC in userspace.**
   Without a userspace IOAPIC the guest reads all-ones from 0xFEC00000 -> "I/O
   APIC ... registers return all ones, skipping" -> it disables legacy IRQ
   routing entirely -> serial IRQ4 never fires.

7. **With an IOAPIC present, the kernel runs a boot-time IO-APIC+timer routing
   check** that panics ("IO-APIC + timer doesn't work!") when there is no i8254
   PIT. Fix: `no_timer_check` on the cmdline. The kernel then uses the in-kernel
   LAPIC timer and the IOAPIC just routes serial.

8. **Serial: console printk is polled (works with no IRQ); the TTY is
   interrupt-driven.** So early boot logs print fine, but `/init`/getty output
   stalls after exactly **16 bytes** (the 16550 TX FIFO) waiting for a THRE
   interrupt. The 16-byte stall is the tell. Need IRQ4 (THRE + RX-data) via the
   IOAPIC. Implement IER/IIR so the driver's ISR can identify the source.

9. **HLT with in-kernel LAPIC (split irqchip) does not exit to userspace** — KVM
   blocks the vCPU in-kernel until an interrupt. Good: a running OS HLTs
   constantly; do NOT treat `KVM_EXIT_HLT` as "guest done" once an OS is booting.
   (The real-mode smoke test uses HLT as "done"; an OS does not.)

10. **MSI-X needs no IOAPIC** (messages go straight to the LAPIC). virtio-blk
    completion via MSI-X worked before the IOAPIC existed. `signalMsi` returns 1
    if delivered, 0 if dropped — log it; a 0 means a destination/vector mismatch.

11. **IOAPIC redirection -> MSI translation**: `addr = 0xFEE00000 | (dest<<12) |
    (dest_mode<<2)`, `data = vector | (delivery<<8) | (trigger<<15) | (trigger<<14)`.
    Level entries: clear remote IRR on `KVM_EXIT_IOAPIC_EOI`.

12. **ACPI minimal set is enough**: RSDP/XSDT/FADT/FACS/MADT/MCFG/DSDT. The PM
    timer (FADT PM_TMR) carries TSC calibration — the kernel's quick-PIT
    calibration fails and falls back to PMTIMER, so no i8254 is needed to boot.

13. **PCIe BARs**: author the host bridge `_SB.PCI0` with a `_CRS` (bus range +
    the pci-mmio32 window) in ASL, compile with `iasl`, `@embedFile` the AML.
    Pre-assign the device BAR inside that window and Linux *claims* it instead of
    reassigning. ECAM config comes via MCFG, not `_CRS`.

14. **Unclaimed PIO/MMIO must be SILENT** on the hot path (reads float high
    all-ones, writes drop). A print per unclaimed access floods the console and
    starves the guest during device probing (the kernel hammers absent ports).

15. **virtio-blk "writes not submitted" was a red herring** — `/init` was
    stalling on the 16-byte console before it could issue the write. Once the
    console worked (IOAPIC), reads AND writes worked end to end (guest write
    lands on the mmap'd host disk image).

## Resolved: continuous stdin (I/O thread + per-device lock)

The old design polled host stdin only on a serial register access, so an idle
shell stopped getting bytes mid-input. Fixed with a dedicated **I/O thread**
(`stdinPump` in main.zig) that blocks on stdin and calls `Serial.pushRx`, which
enqueues into an RX FIFO and raises IRQ4 via the IOAPIC -> `signalMsi`. The
in-kernel LAPIC wakes the (possibly HLT-blocked) vCPU, so input flows even when
the guest is idle. Notes:

- `KVM_SIGNAL_MSI` is a vm-fd ioctl and is designed to be called from a thread
  other than the one in `KVM_RUN`; that is how async interrupts get injected.
- This is the first real instance of the **D3 per-device lock**. Two devices are
  now touched from two threads: serial (RX ring) and the IOAPIC (redir table read
  on raise). Each got a lock. **Lock order is serial -> ioapic**, enforced by
  raising the IRQ only after releasing the serial lock, and by reading the redir
  entry under the ioapic lock then releasing it before the `signalMsi` syscall.
  No lock is ever held across a blocking/slow syscall (the serial TX `write` and
  the IRQ raise both happen after the serial unlock).
- Host terminal goes into **raw mode** (termios: clear ICANON/ECHO/ISIG/IEXTEN,
  IXON/ICRNL; VMIN=1/VTIME=0) so each keystroke reaches the guest and the guest
  does its own echo. `oflag` is left alone (stdout shares the tty and relies on
  ONLCR). Restored on exit via `defer`. With ISIG off, Ctrl-C reaches the guest;
  exit nether by powering off the guest. A SIGKILL leaves the tty raw (`reset`).
- The thread is detached and reclaimed at process exit (it is blocked in `read`).

## Methodology that worked

- **Offline-first.** Build + unit-test every component by cross-compiling to
  `x86_64-linux` and running tests on the host. The live boot is the only thing
  that needs hardware; each live bug was unfindable offline but the *components*
  were de-risked there. Pre-building the IOAPIC/MSI-X/ACPI offline turned the box
  session into "wire and confirm + fix 2 things".
- **Trace gated by a marker file** (`nether-trace` in cwd): runtime toggle, no
  rebuild, no env/args (which 0.16 dropped). Trace points on PCI config, virtio
  feature/queue programming, notify, MSI, IOAPIC raise.
- **Separate stdout (serial) from stderr (trace).** They interleave at the byte
  level in one file (`NETHER-INIT-STAR[trace]...`); always `> ser.log 2> tr.log`.
- **vCPU state dump on triple-fault/SHUTDOWN** (regs+sregs: rip, cr0/3/4, efer,
  cs fields). Then disassemble `vmlinux` at the faulting vaddr to find the
  instruction (map phys->vaddr via the PT_LOAD with that paddr).

## Zig 0.16 specifics

- Use `std.os.linux` directly for syscalls: open/mmap/munmap/read/write/ioctl/
  errno/eventfd/clock_gettime/lseek/fcntl. `std.posix.open`/`getenv` are gone or
  churned; the file API now needs an `Io`. Env vars unavailable -> marker file.
- `linux.errno(r)`, not `E.init`. `PROT` is a packed struct now
  (`.{ .READ = true, .WRITE = true }`); `mmap` takes typed `PROT`/`MAP`.
  `timespec` has `.sec`/`.nsec`.
- `build.zig`: `addExecutable{ .root_module = b.createModule(...) }`. Tests target
  the host (`b.resolveTargetQuery(.{})`) so `zig build test` runs; the exe
  defaults to cross `x86_64-linux`. `@embedFile("dsdt.aml")` for the AML.
- ArrayList API is mid-churn; fixed-capacity arrays sidestep it.
- **macOS host**: native linking needs
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools` when xcode-select points
  into Xcode.app. Cross-compile is unaffected. `zig` itself was at
  `/etc/paths.d/zig` (root-owned).
- **Pin the stable toolchain.** This code targets **0.16.0 stable**
  (`~/Library/zig/0.16.0/zig`), but several dev nightlies are also installed and
  `/etc/paths.d/zig` points `zig` at one of them. The APIs diverge in *both*
  directions, so a wrong toolchain fails to build:
  - stable: `std.os.linux.PROT` is a **packed struct** (`.{ .READ = true }`);
    nightly 2135 made it a **namespace of bit constants** (`PROT.READ`).
  - stable: there is **no `std.Thread.Mutex`** (it moved); only
    `std.atomic.Mutex` (a `tryLock`-only spinlock primitive) and `std.Io.Mutex`
    (needs an `Io`). nightly 2135 still has `std.Thread.Mutex`.
  We use a tiny spin `Lock` (`src/lock.zig`) over `std.atomic.Mutex` so the
  freestanding device models need neither. Build/test with the stable path
  explicitly until `/etc/paths.d/zig` is repointed at `~/Library/zig/0.16.0`.

## AWS box workflow

- **KVM requires bare metal** (only `*.metal` exposes `/dev/kvm` + VT-x). Smallest
  x86 metal is 96 vCPUs (`c5.metal`). The on-demand/spot vCPU quota must be >=96
  (defaults are far lower): on-demand `L-1216C47A`, spot `L-34B43A08`, region
  us-west-2. Spot `c5.metal` ~$1-1.5/hr vs ~$4 on-demand.
- Metal takes 5-15 min to boot; SSH/`/dev/kvm` aren't up immediately.
- **zsh does not word-split unquoted `$VAR`** — `$SSH "cmd"` runs the whole string
  as one command. Use an array (`ssh "${SSHK[@]}" ...`) or inline ssh.
- Kernel: `x86_64_defconfig` + `scripts/config -e PVH SERIAL_8250_CONSOLE
  BLK_DEV_INITRD DEVTMPFS DEVTMPFS_MOUNT KVM_GUEST PARAVIRT PCI PCI_MSI VIRTIO
  VIRTIO_PCI VIRTIO_BLK` then `make olddefconfig && make -j96 vmlinux`
  (~5-8 min on 96 cores). Use the resulting `vmlinux` (ELF, has the PVH note).
- initramfs: static busybox (busybox.net musl binary) + `/init` script,
  `chmod +x /init` (forgetting it -> "No working init found"), then
  `find . | cpio -o -H newc | gzip`.
- Cache `vmlinux`/`initramfs` in S3 (`scripts/artifact-cache.sh`) to skip the
  rebuild next session; `disk.img` is trivial to recreate (`dd` + a marker).
- Always tear down: terminate instance, then delete the SG (after the metal host
  fully terminates, or DeleteSecurityGroup hits a DependencyViolation), delete
  the key pair, remove the local `.pem`.
