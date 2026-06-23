# Nether - Roadmap

**Status (verified on a bare-metal KVM host):** the substrate runs live, Nether
**PVH-boots Linux 6.12 to an interactive shell**, the userspace IOAPIC routes
serial IRQ4 (console no longer stalls at 16 bytes), and **virtio-blk reads and
writes work end to end** (the guest enumerates the device over the ACPI PCIe host
bridge, claims its BAR, and the kernel reads/writes `/dev/vda` with MSI-X
completions, writes landing on the host image). Built and unit-tested offline,
awaiting live verification: **continuous interactive stdin** via a host I/O
thread that feeds the serial RX and raises IRQ4 so an idle shell still receives
input (the first concrete [D3](decisions.md) per-device-lock instance);
**virtio-vsock** (the swerver<->guest channel); and **virtio-net** (a tap-backed
NIC), which completes the Phase 3 datapath device set (block + net + MSI-X) - so
the win condition is now gated on a live boot of a networked image rather than on
any missing device. See [decisions.md](decisions.md) D8 for the PVH gotchas, D6
for the irqchip/IOAPIC, and D3 for the concurrency model.

Re-cut from the original six-phase plan. Two changes from the first draft:

1. A **platform-substrate phase (1.5)** is pulled out of "OVMF boots." That line
   secretly depends on fw_cfg, a minimal static ACPI set, the exit dispatcher,
   and the firmware floor - none of which are OVMF itself.
2. **ACPI is split.** The minimal static tables move up to Phase 1.5 (Linux needs
   MCFG/MADT/FADT to boot over virtio-pci); the hard ACPI - SRAT/SLIT, per-CPU
   SSDT, hotplug AML - stays in Phases 4-5 where it belongs.

The win condition is **Phase 3**: a clean modern-only VMM that boots a Linux disk
image over virtio-block/net with MSI-X. Everything past it is bonus, and each
later phase is its own project measured in months.

---

## Phase 0 - KVM skeleton

VM, vCPU, memory regions, `KVM_RUN` loop, serial out.

- `KVM_CREATE_VM`, `KVM_CREATE_VCPU`, `mmap` of `kvm_run`.
- `KVM_SET_USER_MEMORY_REGION` for a flat region.
- The run loop: dispatch on `KVM_EXIT_IO` / `KVM_EXIT_MMIO` / `KVM_EXIT_HLT`.
- 16550 serial as the first device, enough to print from a hand-loaded stub.

**Done when:** a tiny code blob runs under `KVM_RUN` and prints over serial.

## Phase 1.5 - Platform substrate

The real first hard milestone. None of this is glamorous; all of it is load-bearing.

- **Guest memory map as single source of truth** - RAM split around the sub-4GB
  PCI hole (TOLUD), high RAM above 4GB, ECAM window, 32/64-bit MMIO windows,
  LAPIC `0xFEE00000`, IOAPIC `0xFEC00000`. One comptime table generates the KVM
  memory regions, the E820/fw_cfg view, MTRRs, and ACPI `_CRS`. (Drift here =
  guest corruption that looks like nothing.)
- **MMIO/PIO exit dispatcher** - device tree keyed by address range; the spine
  everything else hangs off.
- **Split irqchip** - `KVM_CAP_SPLIT_IRQCHIP` (LAPIC in kernel, IOAPIC/PIC in
  userspace); irqfd + ioeventfd plumbing on the I/O thread.
- **fw_cfg** - the DMA interface plus the ACPI linker/loader command stream, so
  stock OVMF can find tables/memory/SMBIOS. See
  [decisions D1](decisions.md#d1-ovmf-coupling-fw_cfg-vs-forked-firmware).
- **Firmware floor** - RTC, ACPI PM block, 0xCF9 reset, kvmclock/TSC.
- **Minimal static ACPI** (comptime) - RSDP, XSDT, FADT, MADT, MCFG, a minimal
  DSDT.
- **Test harness** - kvm-unit-tests as the inner loop (it exercises APIC/IOAPIC
  routing, PCI, MSI, PM timer and reports over serial); serial golden-output
  tests. See [decisions D5](decisions.md#d5-test-harness).

**Done when:** kvm-unit-tests' core APIC/PCI suites pass, and the substrate can
present a PCIe host bridge + the firmware floor to a guest.

## Phase 2 - OVMF boots

OVMF reaches the UEFI shell on top of the substrate.

- Map OVMF_CODE.fd / OVMF_VARS.fd.
- Verify OVMF consumes fw_cfg (memory, ACPI linker-loader) cleanly.
- Wire OVMF debug output (debug port) into the host log for triage.

**Done when:** OVMF reaches the UEFI shell with no hand-holding.

## Phase 3 - Boot Linux (WIN CONDITION)

virtio-pci block and net, MSI-X, boot a Linux disk image.

- virtio-pci-modern transport; virtqueue datapath (zero-alloc, in-process for
  block to start).
- MSI-X: table in BAR, intercepted writes → `KVM_SET_GSI_ROUTING` + irqfd.
- virtio-blk backed by a disk image; virtio-net (tap, or vhost-net early - see
  [decisions D2](decisions.md#d2-which-devices-go-out-of-process)).
- virtio-rng/console as warm-ups.

**Done when:** a stock Linux cloud image boots to a login prompt over
virtio-block/net with MSI-X interrupts.

## Phase 4 - Boot Windows

The difficulty cliff. Windows is a brutal ACPI conformance test.

- Full DSDT/SSDT, per-CPU objects, correct `_CRS`/`_PRT`.
- SMP.
- Whatever device conformance Windows demands that Linux forgave.

**Done when:** Windows boots and is stable.

## Phase 5 - Passthrough, hotplug, NUMA

- VFIO passthrough (NVMe, NIC, GPU) through the IOMMU; optional virtio-iommu.
- CPU and memory hotplug - **hotplug AML** (GPE blocks, `_EJ0`, `_STA`).
- SRAT/SLIT and NUMA topology.

## Phase 6 - Snapshot, then live migration

- **Snapshot/restore** - enumerate *all* architectural state to GET/SET: regs,
  sregs, all MSRs, xsave/xcrs, debugregs, lapic, mp_state, vcpu_events, and
  **kvmclock + TSC** (the time-corruption traps). Per-device serialization with a
  **version tag from day one**.
- **Live migration** - dirty-page tracking (`KVM_GET_DIRTY_LOG`), iterative
  pre-copy, device-state stream. The real boss; team-quarters of work elsewhere.

---

## Platform track (thesis-driven)

These are not a seventh phase - they are reprioritizations the
[thesis](thesis.md) imposes on the phases above, captured here so the edge
product shapes the core instead of being bolted on. The principle: **build the
edge path forward of the general-VMM path**, but never ahead of the Phase 3
done-line.

- **Embeddable core from Phase 0.** Library + thin binary, allocator injected,
  no process-global state, device I/O expressed as fds. Costs ~nothing now;
  enables swerver to host Nether later. (Already true of the Phase 0 scaffold.)
  Make the host boundary a hard *compile-time* seam (not a convention) and plan
  the core to export both a Zig API and a C ABI from one build. See the apprt and
  one-library-two-ABIs patterns in
  [references/ghostty-patterns.md](references/ghostty-patterns.md) (1, 2).
- **vsock promoted to the spine** (lands with the virtio work in Phase 3+).
  The swerver↔guest channel, integrated via swerver's park-and-resume pattern.
  The pure protocol engine is in-tree (`src/virtio_vsock.zig`): the 44-byte
  header codec, the per-connection state machine (REQUEST/RESPONSE/RW/SHUTDOWN/
  RST and credit), and credit-based flow control, with a fixed-pool connection
  table and outbound staging ring (snapshot-friendly by construction) and a
  host-facing event/`send`/`connect`/`close` API decoupled from the transport.
  The device wiring is in too (`VsockDev`): a `virtio.Backend` over three
  virtqueues (RX/TX/event) that copies guest TX packets into the engine and
  drains staged output back onto the guest's RX buffers, carrying the first
  two-threaded D3 per-device lock (vCPU-thread kicks vs host-thread `host*`
  calls; the lock is released before the MSI signal, matching serial/IOAPIC).
  It is wired into `main.zig` behind a `nether-vsock` marker as PCI 0:2.0 with an
  echo exerciser on port 1234. Unit- and fuzz-tested offline (the guest's TX
  packets are attacker-controlled); live boot verification and the real
  swerver-side listener are the remaining steps.
- **Snapshot-aware device models from Phase 3.** Don't ship a device whose state
  can't be serialized; snapshot-fork (boot once → clone per request) is the edge
  product, so the Phase 6 "snapshot" work is really a constraint applied early.
  Target fixed-size, pool-allocated, ref-countable, serializable-by-construction
  state; see the paged-storage pattern in
  [references/ghostty-patterns.md](references/ghostty-patterns.md) (6).
- **Concurrency model: per-device lock now, message-passing later.** D3 is
  resolved with per-device locks (first instances: serial RX, IOAPIC raise). The
  scaling path is a mailbox/SPSC-queue model and a libxev event-loop I/O thread;
  see [references/ghostty-patterns.md](references/ghostty-patterns.md) (3, 4),
  adopted when lock contention or a second host input source forces it.
- **Server-side console.** The VT engine exists in-tree (`src/vt/`): the
  vendored parser plus a Nether-authored screen grid (`Screen.zig`, with UTF-8),
  both fuzz-smoked, and the **console tee is wired** (the serial device mirrors
  guest output into a `Screen`, so the VMM holds a live render; dumped on exit
  under trace) with **scrollback** (a ring of evicted rows; the exit dump shows
  the full boot log). That unlocks console-state snapshots and grid-level golden
  tests. The grid handles the alternate screen and scroll regions, so full-screen
  TUIs (vim/less/htop) render correctly, and an **interactive web console** is
  wired (`src/webconsole.zig`: the server renders the live grid to HTML, a polling
  page displays it, and key presses POST to `/input` which feeds the serial RX;
  opt-in via a `nether-web` marker, port 9000). The console subsystem is
  feature-complete; only the small DECOM / wide-character grid bits remain. See
  [references/ghostty-patterns.md](references/ghostty-patterns.md) (2, 5) and
  [decisions.md](decisions.md) D5.
- **PVH / direct-boot fast path** beside OVMF. Linux-only edge guests boot via
  PVH (fast, no UEFI); OVMF stays for general/Windows guests. Slots alongside
  Phase 2-3 rather than replacing them.
- **Per-VM-per-worker ownership** as the concurrency model (see
  [decisions.md D3](decisions.md)) - one swerver worker owns one guest's device
  state, containing the vCPU/I-O race.

## aarch64 + Apple HVF (active)

Promoted from "later": the dev host is Apple Silicon, where Hypervisor.framework
runs aarch64 guests, so an HVF backend turns the Mac itself into a live KVM-class
host (no remote box) - and aarch64 is a real production target (Graviton, ARM
servers), not throwaway. This is the deferred aarch64 platform pulled forward,
done as a second hypervisor backend behind the seam.

The build-out arc (offline-first chunks):

1. **Backend seam (done).** `vm.zig` is now a hypervisor-agnostic wrapper (guest
   memory + region table + accessors); the hypervisor work (region mapping, IRQ
   setup, vCPU create, the run loop, boot entry) is a backend selected at
   comptime by host OS - `kvm_backend.zig` (Linux/x86-64) and `hvf_backend.zig`
   (macOS/aarch64), chosen in `backend.zig`. KVM is the full impl; HVF is a
   compiling scaffold (every op returns Unimplemented) so the macOS build and the
   offline test build are green today. See [decisions.md](decisions.md) D9.
2. **HVF skeleton (done).** `hvf.zig` (hand-rolled framework bindings) +
   `hvf_backend.zig`: `hv_vm_create` + `hv_vm_map` (guest RAM), `hv_vcpu_create`
   and a run loop that decodes data-abort (MMIO) exits to the device Bus and
   steps the PC, plus an aarch64 boot entry (PC + PSTATE). A hand-assembled
   aarch64 blob prints over an MMIO UART and powers off via a sentinel - first
   light on the Mac. build.zig links Hypervisor.framework on macOS; the binary is
   codesigned with the `com.apple.security.hypervisor` entitlement (ad-hoc for
   local dev). See [running-on-hvf.md](running-on-hvf.md).
3. **aarch64 substrate (in progress).** Done: **PSCI** power firmware (the run
   loop decodes `hvc` exits - SYSTEM_OFF/RESET become power requests, the arm64
   analog of the ACPI PM block) and a real **PL011 UART** (`pl011.zig`: DR/FR
   plus the AMBA PrimeCell ID registers so Linux's driver binds; TX to a host
   sink, an RX ring for host input, offline-tested). Remaining: the framework GIC
   (`hv_gic`, the in-kernel LAPIC analog), the ARM generic timer (delivered via
   the GIC), and a full aarch64 memory map - these are exercised by a real OS, so
   they land with step 4.
4. **aarch64 Linux boot (DONE).** An arm64 Alpine kernel (6.12) **boots under HVF
   on Apple Silicon all the way to an interactive userspace shell.** The pieces:
   the **DTB generator** (`dtb.zig`), the aarch64 memory map (`memmap_arm.zig`),
   the framework **GICv3** (`hv_gic`: distributor + redistributor + MSI region),
   the **generic timer** (delivered via the GIC), **PSCI** (HVC), the **PL011**
   console, and the `Image` + `X0 = DTB` boot path (`macBootLinux`). The keystone
   was **MPIDR_EL1**: GICv3 affinity routing requires each vCPU's MPIDR set before
   the framework will associate (and MMIO-intercept) its redistributor - without
   it `hv_gic_get_redistributor_base` returns BAD_ARGUMENT and all redistributor
   registers fall through. The redistributor *region* is ~32 MiB (sized for max
   vCPUs), placed clear of the UART/RAM, and its base is queried from the
   framework and written into the DTB. Trapped system-register accesses (EC 0x18)
   are emulated RAZ/WI. The kernel reaches `Run /init`, runs Alpine init, and
   drops to the initramfs recovery shell (it only lacks Alpine boot media). The
   shell is **interactive**: host stdin feeds the PL011 RX, which raises its SPI
   through the GIC (`hv_gic_set_spi`) so the guest tty reads it - typing a command
   runs it and prints back. With a real rootfs (the Alpine aarch64 minirootfs
   repacked as an initramfs with a tiny `/init`; recipe in
   [running-on-hvf.md](running-on-hvf.md)) it boots straight to a proper Alpine
   busybox shell as root. Next: virtio on aarch64 (step 5).
5. **virtio on aarch64 (working end-to-end: virtio-console datapath live).** Two
   transports exist behind the shared backends:
   - **virtio-mmio** (`virtio_mmio.zig`) - unit-tested and its DTB nodes parse
     (they appear under `/proc/device-tree`), but stock Alpine kernels build
     `VIRTIO_MMIO` as a module (not `=y`), so nothing binds. Kept as the clean
     path for a `CONFIG_VIRTIO_MMIO=y` kernel.
   - **virtio-pci** (the path stock kernels support): a generic-ECAM host bridge
     (`pci.zig` made ECAM-base-configurable) + a `pcie@...` DTB node (ranges,
     bus-range, 64-bit non-prefetchable MMIO window) + a window-wide dispatcher
     routing to the device's live BAR. **The virtio-rng device now fully
     enumerates AND its BAR is assigned and the device enabled**: the guest log
     shows `BAR 0 [mem 0x8000000000-0x8000007fff 64bit pref]: assigned` then
     `virtio-pci 0000:00:01.0: enabling device (0000 -> 0002)`, and the device
     registers on the virtio bus as `virtio0`. The virtio core resets it,
     negotiates features over the BAR MMIO, and acknowledges it.
   - **DTB is QEMU-equivalent and `dtc`-clean** (installed `qemu`/`dtc`, dumped a
     real `-M virt` DTB and diffed the `pcie`/GIC nodes; fixed the GIC
     `#address-cells`/`#size-cells`/`ranges`, the `interrupt-map` parent-address
     cells, and added both the 32-bit and 64-bit MMIO windows). All correct - but
     the DTB was never the blocker.
   - **THE ROOT CAUSE (solved): a zero PCI class code.** Our config space left the
     class code bytes (0x09-0x0b) unset, so the device reported `class 0x000000`.
     Linux's resource assigner `__dev_sort_resources()` (drivers/pci/setup-bus.c)
     begins with `if (class == PCI_CLASS_NOT_DEFINED || class ==
     PCI_CLASS_BRIDGE_HOST) return;` - so a device whose `class >> 8` is 0 is
     **skipped entirely by the assign pass**, its BARs never added to the
     assignment list. That is exactly why our BAR stayed unassigned ("not claimed;
     can't enable device") while QEMU's devices (class `0x020000` net,
     `0x00ff00` rng) were assigned. The fix is a one-liner in `virtio.zig
     buildConfig`: write a real per-type class (net `0x0200`, block `0x0100`,
     console `0x0780`, else `PCI_CLASS_OTHERS 0x00ff`) at config offset 0x0a. The
     `: assigned`/`enabling device` log lines are `pci_info` level and print
     regardless of `dyndbg`, which is what finally exposed the difference - and
     retroactively explains the old "trace-diff": the claim-vs-assign framing and
     the `msi-map`/`preserve_config` theories were all red herrings; the assign
     pass was silently filtering the device on class.
   - **Datapath proven end-to-end via virtio-console.** This minimal Alpine
     minirootfs ships no kernel modules (`/lib/modules` absent) and the kernel has
     only `virtio_console`/`virtio_rproc_serial` built in - so `virtio_console`
     (`virtio_console.zig`, device_id 3) was added as the leaf that actually binds
     and creates `/dev/hvc0`. Both directions of the virtqueue DMA datapath now
     work live on HVF:
       * **TX** (guest -> host): `echo X > /dev/hvc0` kicks the transmitq; the
         backend walks the descriptor chain, reads guest memory over the assigned
         BAR, and emits to host stdout.
       * **RX** (host -> guest): `pushRx` fills a posted receiveq buffer and raises
         the completion; the guest reads it from hvc0.
   - **Two interrupt paths, both wired and proven:**
     * **MSI-X (preferred)** via a GICv2m frame. The DTB describes an
       `arm,gic-v2m-frame` child of the GIC (doorbell at `msi_base`, SPI range =
       the framework's reserved top-of-SPI window) and `msi-parent` on the pcie
       node; the framework's MSI range is clamped to the gic-v2m limit
       (`base + count <= V2M_MAX_SPI = 1019`, which the framework's reported
       exclusive top of 1020 trips by one). The guest then enables MSI-X and
       `virtio.Device` delivers completions by forwarding the guest-programmed
       message (`addr`, `data` = the allocated SPI intid) to `hv_gic_send_msi`.
       Proven: `/proc/interrupts` shows three `GICv2m-PCI-MSIX-0000:00:01.0`
       vectors (config/input/output) and the input/output counts climb on RX/TX.
     * **Legacy INTx (level)** fallback for a kernel with no MSI domain: Interrupt
       Pin = INTA (config 0x3d) routed via the pcie interrupt-map to a GIC SPI;
       `virtio.Device` drives the line as a level via `intx_fn` -> `hv_gic_set_spi`
       (raise on ISR set, lower on ISR read). Also proven live (GIC SPI 36 Level,
       count climbs per RX) before MSI-X was added.
   - **Multiple virtio-pci functions on one bus (DONE).** `PciBarWindow` now
     dispatches the whole 64-bit BAR window across a set of devices (each matched
     by its live BAR), and each function gets its own MSI-X vectors + per-slot INTx
     line. Demonstrated with two functions: `0:1.0` virtio-console and `0:2.0`
     virtio-blk, both enumerated with BARs assigned and MSI-X bound.
   - **virtio-blk live (DONE).** The leaf driver is a module, but the matching one
     (same kernel version, no vermagic mismatch) ships in Alpine's netboot
     `initramfs-virt`; dropping `virtio_blk.ko` into our initramfs and `insmod`-ing
     it binds our `0:2.0` function as `/dev/vda` (2048 512-byte sectors over a 1 MiB
     in-memory disk). `head -c /dev/vda` reads back the on-disk signature, proving
     the full block datapath (request chain -> disk read -> DMA -> used ring ->
     MSI-X completion) on aarch64/HVF. Recipe in running-on-hvf.md.
   - **virtio-vsock live (DONE) - the host<->guest control channel.** Function
     `0:3.0` (opt-in via a `nether-vsock` marker), guest CID 3 / host CID 2, the
     host listening on port 1234 and echoing (`virtio_vsock.zig`, the same engine
     the x86 path uses). The guest vsock stack is module-only and was NOT in the old
     netboot initramfs, and Alpine had moved `linux-virt` past our pinned kernel, so
     the kernel was refreshed to **6.12.93-0-virt** (image + all modules pulled from
     one `linux-virt` apk to guarantee a vermagic match). Loading `vsock.ko` +
     `vmw_vsock_virtio_transport_common.ko` + `vmw_vsock_virtio_transport.ko` binds
     our `0:3.0` function; a tiny static aarch64 vsock client
     (`tools/vsock_client.c`, since busybox has no vsock tool) connects to host
     CID 2:1234, sends a line, and prints the echo
     (`VSOCK_ECHO: HELLO_FROM_GUEST_VSOCK`) - the full vsock datapath (3 queues,
     connection state machine, credit flow control, MSI-X) over virtio-pci. Boot,
     SMP, and virtio-blk re-verified on the refreshed kernel.
   - **Agent runtime (DONE) - exec-over-vsock REPL.** The keystone that makes the
     sandbox an agent runtime: a persistent guest agent (`tools/agent.c`, static
     aarch64) auto-started by `/init`, which connects to the host's agent control
     port (5000) and serves a stream of newline-terminated commands - running each
     through `/bin/sh` and streaming stdout+stderr back over vsock. The host
     (`agentEvent` + `agentStdinPump`, opt-in via a `nether-agent` marker) turns the
     sandbox into a REPL: host stdin lines become in-guest commands and their output
     comes back to host stdout (the PL011 console is output-only in this mode).
     Proven live: piping `whoami / uname -srm / nproc` runs them in the guest and
     prints `root / Linux 6.12.93-0-virt aarch64 / 4`. In-sandbox code execution
     over the control channel, no network/ssh/shared FS - the host<->guest mechanism
     the agent platform is built on. `VsockDev.hostSend` is the locked host-thread
     path; the agent connection is the proven guest->host direction.
   - **Agent control protocol v1 (DONE) - framing + exit status.** The agent now
     frames each reply: it streams the command's stdout+stderr, then a trailer
     `0x1e<exit-code>\n`. The host (`AgentCtx.onRecv`) parses it - printing the
     output and an `[exit N]` line - so a programmatic driver can tell where a
     command's output ends and whether it succeeded. Proven: `true`/`false`/
     `sh -c 'exit 7'`/`ls /nonexistent` return exits 0/1/7/1 with stderr captured.
     This is the request/response shape the platform needs to drive the sandbox.
   - **Control socket (DONE) - the programmatic API.** A `nether-control` boot opens
     a Unix-domain socket (`/tmp/nether.sock`); a client connects and drives the
     in-guest agent without owning this process's stdio. Command lines from the
     client are forwarded to the agent over vsock (`controlListener`), and the
     agent's framed replies are relayed back through a pipe (`controlRelay`). Proven
     live: `nc -U /tmp/nether.sock` with `whoami/uname/.../false` returns each
     command's output and `0x1e<exit>` framing (root, kernel, 42, exit 1). So the
     platform spawns nether per sandbox and attaches to its control socket to exec
     and collect results.
   - **Per-sandbox config (DONE).** A `nether.conf` (`key=value`, `#` comments) read
     from the cwd lets the platform give each sandbox a distinct `control_socket`
     path (a configured path also enables control mode without a marker), so many
     sandboxes run on one host. Proven: with `control_socket=/tmp/nether-sb7.sock`
     and no markers, nether binds that path and serves it. The platform writes one
     config per sandbox and launches. Every mode is now config-driven too
     (`net`/`vsock`/`agent`/`control`/`restore`/`snapshot` as `key=1`, markers kept
     as a legacy fallback via `modeOn`), so a single `nether.conf` fully describes a
     sandbox: proven with `cpus=2 ram_mb=384 control_socket=... net=1` (no markers)
     bringing up vsock + net + the control socket and serving a wget end to end.
     `cpus` and `ram_mb` are also config-driven
     (clamped to 1..8 vCPUs sized by MAX-sized SMP arrays, and RAM >= 256 MiB):
     proven with `cpus=2 ram_mb=384`, the guest reports `nproc` 2 and ~384 MiB and
     `SMP: Total of 2 processors activated`. So the platform sizes each sandbox.
   - **Metering (DONE) - the meter pillar.** A host-intercepted `__stats__` control
     command reports per-sandbox usage so the platform can settle per consumption
     (x402): `uptime_ms`, `ram_mb`, `cpus`, `commands` run, and `bytes_in/out`.
     Counters live in a `Metering` struct shared by the control threads; the command
     is answered by the host without touching the guest, and is not itself counted.
     Proven live: after 3 commands, `__stats__` over the socket returns
     `commands=3 bytes_in=27 bytes_out=287` etc. Nether exposes the usage; the
     billing plane (the platform/x402) settles on it.
   - **Network egress metering (DONE).** slirp counts payload bytes that traverse
     the NAT (`tx_bytes` guest->internet, `rx_bytes` internet->guest), surfaced via
     `__stats__` as `net_tx_bytes`/`net_rx_bytes`. Bandwidth is a real
     host-measurable billing dimension. Proven: a `wget http://example.com` over the
     control socket moves the counters to `net_tx_bytes=145 net_rx_bytes=1014` (DHCP
     stays 0, as it is handled internally, not NAT'd).
   - **Egress firewall (DONE) - the govern pillar.** An untrusted agent with
     internet must not reach the host LAN, loopback, or cloud metadata
     (169.254.169.254), and should be confinable to an allowlist. slirp's
     `egressAllowed` denies special-use ranges by default (0/8, 10/8, 100.64/10,
     127/8, 169.254/16, 172.16/12, 192.168/16, multicast, reserved) and permits the
     public internet; `net_allow` CIDRs override the default-deny, `net_block` CIDRs
     deny otherwise-public destinations, and `net_open=1` disables it. Enforced at
     TCP connect (blocked SYN -> RST, fast connection-refused) and UDP send (drop);
     denied attempts metered as `net_blocked`. Unit-tested (deny/allow/block/parse)
     and proven live: guest fetches http://example.com (allowed), is refused on
     http://192.168.1.2 with a RST, `__stats__` shows `net_blocked=1`.
   - **Bandwidth cap (DONE) - govern.** `net_rate_kbps` token-bucket-limits the
     download (internet->guest) rate, so an untrusted sandbox can't saturate the
     host uplink or run up unbounded bandwidth cost (the metered dimension). When the
     bucket empties the poll loop stops reading host sockets and TCP backpressure
     slows the sender (lossless, no drops); burst ~250 ms smooths it. Unit-tested
     (refill/cap math, kbps->bytes) and proven live: a 4 MB fetch is ~2 s uncapped,
     ~9 s at 4000 kbps (500 KB/s), ~17 s at 2000 kbps - proportional and matching.
   - **File push/pull over the agent channel (DONE) - the run pillar.** Getting a
     task payload into the sandbox and artifacts back out, host-mediated so binary
     never crosses the line-oriented control socket: the operator sends text commands
     `__put__ <hostpath> <guestpath>` / `__get__ <guestpath> <hostpath>`; the host
     moves the bytes over vsock with length framing. `tools/agent.c` grew a PUT/GET
     state machine (`__PUT__ <path> <len>\n<raw bytes>` -> file; `__GET__ <path>` ->
     `OK <len>\n<raw bytes>`); the host (`controlPut`/`controlGet`, a diverted
     `Capture` of the agent's reply) reads/writes the host file. Two real vsock bugs
     surfaced and were fixed: (1) host->guest packets exceeding the guest's 3776-byte
     RX buffer were silently truncated by `scatter` (MAX_PAYLOAD 4096 -> 3072); (2)
     the RX direction was coupled to that cap, so large guest->host packets truncated
     and the 64 KiB advertised window stalled big pulls on dropped per-packet credit
     updates - decoupled (RX scratch sized for a 64 KiB guest packet; advertised
     window raised to 32 MiB since the host consumes synchronously). Proven live:
     1 B / 100 KiB / 1 MiB / 8 MiB random files round-trip byte-identical (md5),
     interleaved with normal commands; missing dir/file fail gracefully.
   - **Hardening pass: guest cannot panic the host (DONE).** Malformed guest input
     is the VMM threat model, so a focused pass closed the guest-reachable panics an
     external review found: (1) a guest-set virtqueue size of 0 divided-by-zero in
     the ring-index modulo - now `virtq.next`/`complete` guard size 0 and
     `virtio.zig` only accepts/enables a nonzero power-of-2 size <= 256; (2)
     guest-influenced address math could overflow/trap - `GuestMem.slice` is now
     overflow-safe (compares against room left, never `off+len`), and `virtio_blk`
     computes `sector*512` with `std.math.mul` and uses saturating adds + room-left
     bounds; (3) the toolchain contract was brittle - `lock.zig` dropped the
     version-volatile `std.atomic.Mutex` for a plain `std.atomic.Value` spinlock, so
     the tree builds on both 0.16.0 stable and recent dev nightlies. New tests cover
     size-0 queues, overflowing slices, an overflowing blk sector, and invalid queue
     sizes (164 total). The coarse bus lock (held across handlers) is documented as
     an intentional safety choice - device models aren't individually thread-safe, so
     it serializes possibly-malicious concurrent vCPU access; per-device locking is
     the scalability follow-up (see io.zig).
   - **Render pillar (DONE).** The platform must be able to show an untrusted
     agent's work. `render.zig` maintains a server-side VT `Screen` (the same parser/
     grid the serial console uses) fed by the agent's command output, so the
     platform can fetch a rendered snapshot of what the sandbox's terminal shows -
     to display, stream, or store as the visible artifact - without the guest
     cooperating. The agent reply stream is teed in with its `0x1e<exit>\n` framing
     stripped and pipe LF mapped to CR+LF (ONLCR), so it renders like a real tty.
     Exposed as the `__screen__` control command; size via `screen_rows`/`screen_cols`
     (default 24x80). Unit-tested (framing strip incl. split-chunk) and proven live:
     after running commands, `__screen__` returns the clean terminal, and a
     `printf 'PROGRESS-XXXXXX\rDONE'` renders as `DONERESS-XXXXXX` (real CR overwrite,
     not log concatenation).
   - **Screen streaming / diff (DONE).** So the platform can *follow* the agent's
     screen cheaply instead of re-pulling the whole grid, `__screendiff__` returns
     only the LIVE rows (the fixed rows x cols grid, not scrollback) that changed
     since the last call - the first call (or after a fresh client connects) emits
     the whole screen. Per-row Wyhash tracks what was last sent; wire format is
     `SCREEN <rows>x<cols>` then `<row-index> <text>` lines (text may be empty =
     cleared) terminated by a blank line. Unit-tested and proven live: diff#1 sends
     the full screen, an unchanged diff#2 sends no rows, and after a new command
     diff#3 sends only the one changed row.
   - **`__shutdown__` lifecycle command (DONE).** An on-demand control-socket command
     (host-intercepted like `__stats__`) for the platform to tear a sandbox down
     cleanly without killing the process: it acks `OK shutting down`, then `stopSandbox`
     takes the guest-PSCI-poweroff path (`power.request(.shutdown)` + `hv_vcpus_exit`),
     so cpu0's run loop returns `.shutdown` and the process exits. Shares `stopSandbox`
     with the runtime-budget watchdog. Proven live: `__shutdown__` -> ack -> clean
     `guest shutdown`, process exits immediately. With the runtime budget this gives
     the platform both ends of sandbox lifecycle (auto-stop + on-demand stop).
   - **Runtime budget (DONE) - govern (time axis).** `max_runtime_s` arms a watchdog
     thread that stops the sandbox after that many seconds of wall clock - a hard cap
     on cost/runaway for untrusted agents, alongside the firewall (reachability),
     bandwidth cap (volume) and cpus/ram (sizing). It uses the guest-PSCI-poweroff
     path: `power.request(.shutdown)` then `hv_vcpus_exit` so the run loop returns
     `.shutdown` and the process exits cleanly. 0 = unlimited. Proven live:
     `max_runtime_s=8` -> "runtime budget (8s) reached; stopping sandbox" -> clean
     `guest shutdown` at ~8 s.
   - **Per-device locking; bus lock off the virtio hot path (DONE).** Both reviews
     flagged the global bus lock held across whole device handlers - a virtio notify
     that does net TX (`send`) or a queue drain serialized ALL vCPU MMIO, an SMP
     scalability wall. The registry is immutable after init, so the bus lock now only
     guards the lookup + the simple, non-self-locked devices (PL011, ECAM, firmware
     PIO). Devices that self-serialize set `self_locked`: the bus releases its lock
     before calling them. The PCI BAR window (all virtio BAR traffic) is self_locked,
     and each virtio `Device` got a `dev_lock` taken at the top of barRead/barWrite -
     so concurrent vCPUs run in DIFFERENT virtio devices in parallel, while the same
     device serializes, and a notify's host I/O no longer holds a global lock.
     `dev_lock` (vCPU<->vCPU) is distinct from and always outside `irq_lock`
     (host<->vCPU interrupt state) - the notify path holds dev_lock then calls
     interruptQueue (irq_lock), so one lock would self-deadlock; backends release
     their own lock before interruptQueue, so no order is ever reversed. Proven live:
     4-vCPU boot, MSI-X interrupts across cores, a 1 MiB vsock file round-trip
     byte-identical, no deadlock; 165 tests pass.
   - **virtio transport-state lock (DONE).** A concurrency review found a real data
     race: `Device.interruptQueue` (called from host RX threads) and the guest's
     MMIO MSI-X/ISR/queue-vector writes (vCPU thread) share isr/msix_enabled/
     queue_vector/msix_table with no common lock (the bus lock covers only the vCPU
     side). Added `Device.irq_lock` guarding exactly those fields at interruptQueue,
     the ISR read/clear, msixWrite, MSI-X enable, reset, and queue_vector writes -
     held only across the field accesses, never a drain or syscall. Consistent lock
     order (bus->irq on vCPU, irq alone on host); a 50k-iteration concurrent test
     guards against deadlock/corruption. Deferred (tradeoffs, not bugs): the coarse
     bus-lock-across-handlers (needs immutable registry + per-device locks first),
     slirp's lock held across socket syscalls (snapshot-under-lock + inject-after),
     and unbounded per-notify ring drains (per-notify budget).
   - **Guest image: net/vsock/agent restored (DONE).** The initramfs had been
     stripped of kernel modules (no `virtio_net` -> no eth0 -> no networking, and no
     vsock). Rebuilt `kernels/initramfs.cpio.gz` from the matched `linux-virt`
     `6.12.93-0-virt` apk: the full `/lib/modules` tree (so `modprobe` resolves
     deps), the static `agent`, and an `init` that loads `virtio_net` + the vsock
     transport, configures eth0 to the slirp plan, and starts the agent. Net, vsock
     and the agent now come up automatically on every boot (procedure in
     docs/running-on-hvf.md; `kernels/` is a local, git-ignored build asset).
   - **NAT idle reaper (DONE).** A long-running untrusted sandbox could exhaust the
     fixed 32-slot TCP/UDP NAT tables with abandoned or half-open connections. The
     poll loop now reaps entries idle past per-state thresholds (connecting 10 s,
     closing 10 s, established 5 min, UDP flow 1 min): each entry stamps `last_ms`
     on activity and `reapStale` frees the rest. Unit-tested; live wget unaffected.
     (Fixed a latent bug found here: the `timeval` struct had `usec` as i64 but
     macOS `suseconds_t` is i32, so `nowMs` read stack garbage - it had only
     "worked" for the metering uptime by luck of a zeroed stack.)
   - **Compute metering: not feasible with `hv_vcpu_get_exec_time` (finding).** That
     API does not count long *native* guest runs - guest code executes directly on
     the host core under HVF, and a compute-bound loop takes few VM exits, so the
     counter barely advances (3 s of tight-loop CPU registered ~4.6 ms). A
     misleading compute number is worse than none, so it was dropped. A real compute
     metric needs a different signal (e.g. periodic forced vCPU exits to sample, or a
     future framework counter); bandwidth + uptime + command count are the working
     billing dimensions for now.
   - **Configurable base image (`restore_from`) (DONE).** `restore_from=<path>` in
     nether.conf selects which snapshot a restore forks from (default `nether.snap`),
     so the platform can pre-bake several base snapshots (python-base.snap,
     node-base.snap, ...) and fork the right one per sandbox. Proven: snapshot,
     rename to `base-a.snap`, restore with `restore_from=base-a.snap` (default
     absent) -> responsive forked guest.
   - **Safe-point SMP snapshot (DONE).** An SMP (4-CPU) cross-process restore used to
     panic in the guest's hrtimer rbtree (`rb_erase` <- `hrtimer_interrupt`)
     DETERMINISTICALLY per capture, because `quiesce` forced vCPUs out at arbitrary PCs
     and could freeze the guest mid-update of a shared kernel structure. `quiesceSafe`
     (main.zig) now captures only at a consistent point: it force-quiesces, then checks
     every vCPU was caught in its idle loop (instruction at PC-4 is the `WFI` - HVF
     emulates WFI and advances PC, so an idle CPU lands at WFI+4). Reading that
     instruction needs a guest page-table walk (TTBR1, 4 KiB/48-bit). If any vCPU isn't
     idle it resumes briefly and retries; an idle guest converges immediately, a busy
     one falls back to best-effort. (HVF absorbs WFI internally - 0 EC_WFX exits/s
     while idle - so we detect the idle PC after the fact rather than parking at a WFI
     exit.) Proven: a 4-CPU base restores 6/6 clean (nproc=4, responsive), 0 panics
     across 3 further fresh captures; the rewind demo is unaffected. The `cpus=1`
     workaround is no longer needed.
   - **NAT throughput is not poll-limited (finding).** A guest fetch of a 20 MB
     host-local file clocks ~69 MB/s via the NAT; internet fetches match host `curl`
     (network-limited). The near-zero in-process RTT keeps the guest's ACKs flowing so
     the TCP window stays open and `poll` returns immediately. An adaptive 5ms/200ms
     poll was A/B'd (0.28 s vs 0.29 s for 20 MB - identical) and reverted; no fix needed.
   - **virtio-net + user-mode networking (DONE).** Rather than a privileged host
     backend (vmnet needs root/an entitlement + XPC), networking is a tiny in-VMM
     stack (`slirp.zig`): the guest's virtio-net TX frames go to it and replies come
     back via `Net.pushRx`, so an unprivileged guest gets a configured `eth0` with
     no tap/bridge/root. It implements ARP, IPv4, ICMP echo and DHCP (address plan
     10.0.2.0/24, QEMU-slirp defaults), unit-tested. Function `0:4.0`, opt-in via a
     `nether-net` marker. Proven live: `udhcpc` gets `lease of 10.0.2.15 obtained
     from 10.0.2.2`, `eth0` comes up `10.0.2.15/24`, and `ping 10.0.2.2` is 0% loss
     (~0.3 ms) - the full virtio-net datapath plus the slirp stack.
   - **Outbound UDP NAT + DNS (DONE).** slirp forwards the guest's UDP through
     ordinary host sockets (no privilege): a per-flow table maps each guest UDP
     flow to a host `SOCK_DGRAM`, a poll thread reads replies and injects them back
     with the address the guest expects. DNS queries to the virtual resolver
     (10.0.2.3:53) are forwarded to a real upstream (8.8.8.8). Proven live:
     `nslookup example.com 10.0.2.3` returns real records. So the guest now has
     real name resolution and outbound UDP with no host networking setup.
   - **Outbound TCP NAT (DONE) - real internet.** The guest's TCP connections
     terminate at a slirp-side state machine bridged to host `SOCK_STREAM` sockets:
     on the guest SYN we start a non-blocking `connect()`; the poll thread completes
     it (`getsockopt(SO_ERROR)`) and sends the SYN-ACK; data relays both ways with
     correct seq/ack and respecting the guest's receive window; FIN/RST close it.
     Window scaling is disabled (omitted from our SYN-ACK) so windows stay 16-bit,
     and the lossless in-process path means no retransmit/congestion logic is
     needed. Proven live: `wget -O- http://example.com` resolves the name (DNS NAT),
     connects (TCP NAT), and returns the full page body - real internet in an
     unprivileged guest. Known limits (fine for the sandbox use case): no window
     scaling (64 KiB cap), no SACK/reordering (lossless path), no idle-conn reaper.
6. **SMP (DONE).** The aarch64 guest boots with multiple vCPUs
   (`ARM_NUM_CPUS`, currently 4). Each core creates and runs its own vCPU on its
   own host thread (an HVF vCPU is bound to its creating thread), so the boot core
   spawns a parked thread per secondary; each creates its vCPU up front
   (establishing its GIC redistributor) and the boot core waits on a barrier
   before building the DTB, so all redistributors exist before the kernel's GIC
   init. Secondaries come online via **PSCI CPU_ON** (`smp.zig` is the rendezvous;
   `hvf_backend.zig handlePsci` adds CPU_ON/AFFINITY_INFO/FEATURES, 32- and 64-bit
   FIDs); the DTB emits one `cpu@N` node per core with `reg` = MPIDR affinity and
   `enable-method = psci`. `io.Bus` gained a coarse lock so concurrent-vCPU MMIO
   cannot race on device state. Proven: `SMP: Total of 4 processors activated`,
   `nproc` = 4, each secondary `Booted secondary processor 0x0N` with its own
   redistributor (128 KiB stride), and the virtio-console datapath + MSI-X still
   work under load. (Clean SMP teardown on guest shutdown is a known rough edge:
   a secondary parked in WFI inside `hv_vcpu_run` is not force-stopped.)
7. **Snapshot / restore (DONE).** The whole live machine can be captured and
   restored - the microVM fork primitive an agent platform is built on. Captured
   state: guest RAM, each vCPU's full register context (GP + PC/SP/PSTATE + the
   SIMD&FP file + the EL1 system registers, including `CNTVOFF_EL2` so the guest's
   view of time stays continuous), the framework **GIC state**
   (`hv_gic_state_create`/`get_data`/`set_state` - the one piece that would
   otherwise be unrecoverable, but Apple exposes it directly), and the virtio
   device + backing-disk state. SMP is quiesced with `hv_vcpus_exit`: an
   orchestrator thread drives a phase machine (`SnapCtl`) and each vCPU
   self-captures/self-restores its own context at a rendezvous (register access is
   owning-thread only) before the orchestrator snapshots/restores the global state.
   Proven live two ways:
   - **In-memory rewind** (opt-in `nether-snapshot`): snapshot a 4-core Alpine guest
     at the shell (`ram=512MiB gic=126405B cpus=4`), let it run (a `/tmp/REWIND_ME`
     file is created, ~130 KB of RAM changes), then restore - the file is gone, the
     RAM is rewound, and the guest stays fully interactive across all 4 cores.
   - **Cross-process fork** (`nether-snapshot-save` writes `nether.snap`; a separate
     run with `nether-restore` rebuilds the VM from it - no kernel/DTB boot, the
     snapshot *is* the guest). A 513 MiB file restores to a fully interactive 4-core
     guest, and a `/tmp/fork_marker` written in the original before the snapshot is
     present in the fork - live filesystem + memory state carried across processes.
   Getting cross-process restore right surfaced three pieces of per-vCPU state that
   in-place rewind never exercised (the original vCPU kept them) but a fresh vCPU
   does not inherit: the **pointer-auth keys** (APIAKEY...; else the first `autiasp`
   faults and the kernel kills the idle task), the **GICv3 CPU-interface registers**
   (ICC_PMR/IGRPEN1/SRE/...; without them the fresh CPU interface masks every
   interrupt and the guest is alive-but-frozen), and the **PL011 IMSC** (else the
   restored console has RX interrupts masked and goes deaf). Code: `hvf_backend.zig`
   (CpuState incl. sys+ICC regs, SnapCtl, capture/restore, GIC state wrappers),
   `hvf.zig` (bindings + the EL1 sys-reg and ICC-reg lists), `virtio.zig`
   (pointer-free `DeviceState` export/import), `pl011.zig` (`State`), `main.zig`
   (orchestrator + `nether.snap` format + the restore path).
   - **Copy-on-write fork.** The RAM region of `nether.snap` is page-aligned and a
     restore maps it `MAP_PRIVATE` (`hvf_backend.mapMemoryCow`) rather than copying
     it: each fork shares the base image's pages through the page cache and only
     copies the pages it writes, so the base file is never mutated and N forks cost
     ~base + per-fork deltas. Proven: fork a guest, write inside it -> the base
     `nether.snap` checksum is byte-identical afterwards; fork the same base again
     -> it sees the original state but not the first fork's writes (isolated COW
     views from one immutable base). Two independent sandboxes from one boot.
   - **Lazy (near-instant) restore.** The restore does NOT invalidate the I-cache
     over RAM up front: the pages are demand-paged COW from the file (already at the
     point of unification) and a freshly created vCPU's I-cache is empty, so there
     is nothing stale to flush (unlike the boot path, which stores the kernel
     through the host mapping right before fetch). Dropping the 512 MiB page-in cut
     time-to-RESTORED from ~1780 ms to ~90 ms (~20x); restore now mmaps + reads only
     the ~1.2 MiB of metadata/GIC/disk, and RAM pages fault in on demand. Verified
     the forked guest still runs correctly with no invalidation.
   Known rough edge: same-host/same-build snapshot format.

The x86-64/KVM path stays the reference backend; its one remaining Phase 3 step
(a live networked boot) is independent of this track. SMP and snapshot on the KVM
path (per-vCPU threads + INIT/SIPI; KVM's GET/SET ioctls + dirty-log) are the
analogous follow-ups there.
