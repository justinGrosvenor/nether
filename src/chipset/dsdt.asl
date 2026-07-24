// Nether DSDT. Compiled with iasl to dsdt.aml, which acpi.zig embeds verbatim.
//   iasl src/chipset/dsdt.asl   (produces src/chipset/dsdt.aml)
//
// Provides S5 soft-off (SLP_TYP 5, matching pm.zig), a PCIe host bridge so the
// guest's PCI core has a bus range and an MMIO window to assign/claim BARs from
// (window [0xC000_0000, 0xE000_0000) = the pci-mmio32 range in memmap.zig; ECAM
// via MCFG), and the VM Generation ID device (fork entropy divergence).

DefinitionBlock ("", "DSDT", 2, "NETHER", "NETHER0", 0x00000001)
{
    Name (_S5, Package (0x04) { 0x05, 0x05, 0x00, 0x00 })

    Scope (\_SB)
    {
        Device (PCI0)
        {
            Name (_HID, EisaId ("PNP0A08")) // PCI Express root bridge
            Name (_CID, EisaId ("PNP0A03")) // PCI root bridge (compatibility)
            Name (_SEG, Zero)
            Name (_BBN, Zero)
            Name (_UID, Zero)
            Name (_CRS, ResourceTemplate ()
            {
                WordBusNumber (ResourceProducer, MinFixed, MaxFixed, PosDecode,
                    0x0000, 0x0000, 0x00FF, 0x0000, 0x0100)
                DWordMemory (ResourceProducer, PosDecode, MinFixed, MaxFixed,
                    NonCacheable, ReadWrite,
                    0x00000000, 0xC0000000, 0xDFFFFFFF, 0x00000000, 0x20000000)
            })
        }

        // VM Generation ID: the guest's stock vmgenid driver (_HID "VMGENCTR")
        // reads a 16-byte GUID at the physical address ADDR returns, and reseeds
        // the CRNG when Notify(VGEN, 0x80) fires. The GUID lives in the top page of
        // guest RAM (reserved out of E820, see pvh.zig), so a fork's fresh GUID is
        // private to its COW copy - the address is memmap.vmgenid_addr (0x0FFFF000
        // for the fixed 256 MiB guest).
        Device (VGEN)
        {
            // A valid _HID promotes this node to a platform device (which the 6.x
            // vmgenid platform_driver binds to); the driver matches the string _CID
            // "VM_GEN_COUNTER" in its table. Hyper-V's "VMGENCTR" _HID is not a valid
            // ACPI id per iasl, so we use a nether vendor id + the _CID for matching.
            Name (_HID, "NETH0001")
            Name (_CID, "VM_GEN_COUNTER")
            Name (_DDN, "VM_GEN_COUNTER")
            // A memory _CRS over the GUID page promotes this ACPI node to a platform
            // device, which the 6.x vmgenid platform_driver needs; the driver still
            // takes the ACPI path (evaluates ADDR) because it has an ACPI companion.
            Name (_CRS, ResourceTemplate ()
            {
                Memory32Fixed (ReadWrite, 0x0FFFF000, 0x00001000)
            })
            Method (ADDR, 0, NotSerialized)
            {
                Return (Package (0x02) { 0x0FFFF000, 0x00000000 })
            }
        }
    }

    // GPE bit 0 is the fork signal: on restore nether writes a fresh GUID, sets
    // GPE0 status bit 0 and raises the SCI; the guest runs this handler, which
    // Notifies the vmgenid device to re-read the GUID and reseed.
    Scope (\_GPE)
    {
        Method (_E00, 0, NotSerialized)
        {
            Notify (\_SB.VGEN, 0x80)
        }
    }
}
