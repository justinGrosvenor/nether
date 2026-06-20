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
pub const gicr_base: u64 = 0x080A_0000; // redistributors
pub const gicr_size: u64 = 0x0002_0000; // 2 64-KiB frames per CPU (1 CPU)

/// PL011 UART.
pub const uart_base: u64 = 0x0900_0000;
pub const uart_size: u64 = 0x0000_1000;
pub const uart_spi: u32 = 1; // SPI 1 (GIC interrupt id 32 + 1)

/// Main RAM starts at 1 GiB (below it is the MMIO/device region).
pub const ram_base: u64 = 0x4000_0000;

/// The standard PL011 reference clock the DTB advertises (24 MHz).
pub const apb_clock_hz: u32 = 24_000_000;
