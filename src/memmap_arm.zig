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

/// Main RAM starts at 1 GiB (below it is the MMIO/device region).
pub const ram_base: u64 = 0x4000_0000;

/// The standard PL011 reference clock the DTB advertises (24 MHz).
pub const apb_clock_hz: u32 = 24_000_000;
