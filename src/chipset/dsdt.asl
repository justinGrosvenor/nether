// Nether DSDT. Compiled with iasl to dsdt.aml, which acpi.zig embeds verbatim.
//   iasl src/dsdt.asl   (produces src/dsdt.aml)
//
// Provides S5 soft-off (SLP_TYP 5, matching pm.zig) and a PCIe host bridge so
// the guest's PCI core has a bus range and an MMIO window to assign/claim BARs
// from. The window [0xC000_0000, 0xE000_0000) is the pci-mmio32 range reserved
// in memmap.zig; ECAM config access comes via MCFG.

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
    }
}
