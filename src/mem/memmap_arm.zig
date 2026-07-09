//! aarch64 guest memory map (the "virt" platform layout), the arm64 counterpart
//! of memmap.zig. These addresses are the single source of truth shared by the
//! device wiring (PL011, GIC), the DTB generator (dtb.zig), and the HVF guest
//! mapping. They follow the de-facto QEMU/cloud "virt" board so stock arm64
//! kernels and bootloaders are happy.
//!
//! The GIC distributor/redistributor bases here are provisional: they must match
//! whatever Apple's hv_gic actually places, which is reconciled when the GIC is
//! wired (the boot chunk). The DTB encoding itself is independent of that.

pub const kib = 1 << 10;
pub const mib = 1 << 20;
pub const gib = 1 << 30;

/// GIC (interrupt controller), low MMIO.
pub const gicd_base: u64 = 0x0800_0000; // distributor
pub const gicd_size: u64 = 0x0001_0000; // 64 KiB
// The framework redistributor *region* is sized for the max vCPUs (~32 MiB), so
// it is placed above the UART and below RAM to avoid overlap. The actual base is
// queried from the framework after the vCPU exists; this is the request/fallback.
pub const gicr_base: u64 = 0x0A00_0000; // redistributor region (clear of GICD/UART)
pub const gicr_size: u64 = 0x0200_0000; // ~32 MiB region (fallback; queried at runtime)

/// PL011 UART.
pub const uart_base: u64 = 0x0900_0000;
pub const uart_size: u64 = 0x0000_1000;
pub const uart_spi: u32 = 1; // SPI 1 (GIC interrupt id 32 + 1)

/// GIC MSI region (GITS-style doorbell), above the redistributor region.
pub const msi_base: u64 = 0x0C00_0000;

/// virtio-mmio device window: one 0x200 region per device, each with its own SPI.
/// Placed clear of the GIC/UART/MSI regions and below RAM.
pub const virtio_mmio_base: u64 = 0x0D00_0000;
pub const virtio_mmio_stride: u64 = 0x200;
pub const virtio_spi_base: u32 = 2; // SPI 0/1 reserved (1 = UART); virtio starts at 2

/// PCIe (virtio-pci): ECAM config window (1 bus) plus two BAR windows, matching
/// QEMU's virt board - a 32-bit non-prefetchable window (the host bridge requires
/// one) below RAM, and a 64-bit window high in IPA space where 64-bit BARs land.
/// INTx legacy interrupt lands on a dedicated SPI.
pub const ecam_base: u64 = 0x1000_0000;
pub const ecam_size: u64 = 0x0010_0000; // 1 bus (256 functions * 4 KiB)
pub const pci_mmio_base: u64 = 0x1100_0000;
pub const pci_mmio_size: u64 = 0x0100_0000; // 16 MiB, 32-bit window
pub const pci_mmio64_base: u64 = 0x80_0000_0000; // 512 GiB, 64-bit window
pub const pci_mmio64_size: u64 = 0x0100_0000; // 16 MiB
pub const pci_io_base: u64 = 0x3eff_0000; // PCI I/O window (CPU side), 64 KiB
pub const pci_io_size: u64 = 0x0001_0000;
pub const pci_intx_spi: u32 = 3; // legacy INTA -> SPI (INTID 35)

/// Main RAM starts at 1 GiB (below it is the MMIO/device region).
pub const ram_base: u64 = 0x4000_0000;

/// vmgenid (VM Generation ID): the guest kernel's `microsoft,vmgenid` driver watches a
/// 16-byte GUID and reseeds the crng when it changes, so a snapshot-forked guest gets a
/// distinct random stream with no agent round-trip. The GUID lives in the TOP page of the
/// mapped RAM, which the DTB `memory` node excludes (so the guest treats it as a device
/// region it can ioremap, not System RAM). The host writes a fresh GUID + pulses this SPI
/// on restore. SPI 8 (INTID 40) is clear of UART (33), virtio, and PCI INTx (35-38).
pub const vmgenid_page: u64 = 0x4000; // 16 KiB reserved at the top of RAM (host-page sized)
pub const vmgenid_spi: u32 = 8;

/// The standard PL011 reference clock the DTB advertises (24 MHz).
pub const apb_clock_hz: u32 = 24_000_000;
