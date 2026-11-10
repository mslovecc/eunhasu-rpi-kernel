# Raspberry Pi 2B Eunhasu / Diretta Kernel V8

## Goal

Build Linux 6.2.15 for Raspberry Pi 2 Model B while preserving the original,
unmodified Eunhasu Diretta modules:

- `alsa_bridge.ko`
- `diretta_direct.ko`

Required kernel release:

`6.2.15-215.fc36.armv7hl`

Required module vermagic:

`6.2.15-215.fc36.armv7hl SMP preempt mod_unload ARMv7 p2v8`

## V8 design

V8 changes the hardware configuration source compared with V6.

1. Extract the final ARMv7 `.config` from the repository's actual Fedora
   `kernel-devel-6.2.15-100.fc36.armv7hl.rpm`. This is the configuration
   associated with the Fedora 6.2.15-100 kernel that the user confirmed boots
   Raspberry Pi 2.
2. Build the matching Linux 6.2.15 source with the same Fedora SRPM patch
   already used by V6.
3. Apply only `config/v8-rpi2-diretta.fragment` for the original Diretta
   vermagic/ABI requirements and built-in SD-root dependencies.
4. Keep Fedora's USB DWC2, EHCI/OHCI, SMSC95XX, LAN78XX, USB networking,
   USB storage and USB audio selections. The workflow asserts the important
   module settings rather than silently accepting a missing driver.
5. Extract and audit the complete original A20 kernel-devel archive from
   `baseline/a20/kernel-devel/`. It is an ABI reference, not the Pi 2 hardware
   configuration.
6. Keep both original Diretta modules byte-for-byte unchanged and package them
   under `lib/modules/6.2.15-215.fc36.armv7hl/extra/diretta/`.

## Boot-chain strategy

V8 intentionally does not reuse the repository's old `initramfs7`. Its
embedded module release belongs to a different kernel build. The V8 package
therefore supplies a `config.txt` that explicitly selects
`bcm2836-rpi-2-b.dtb` and sets `auto_initramfs=0`.

To support direct root mounting without an initramfs, the SD host controller,
MMC block layer, partition parser and ext4 filesystem must be built into the
kernel. The workflow checks these requirements and checks that the DTB
contains the Pi 2 USB controller / LAN9514 / SMSC95XX topology.

The original `cmdline.txt` is copied unchanged. In particular, its root
PARTUUID must still match the user's SD card.

## Static checks versus runtime proof

The workflow checks the release, vermagic, ARM ELF type, mandatory exported
symbols, configuration provenance, built-in SD path, expected USB/audio
modules, DTB contents, module installation and package checksums.

These checks do **not** prove complete binary ABI compatibility. Since
`CONFIG_MODVERSIONS` is disabled, there is no symbol CRC validation. A
successful build is not evidence that the board boots or that Diretta modules
load correctly.

## V8 acceptance sequence

1. Inspect the Actions artifact and its config delta against Fedora's final
   `6.2.15-100` config.
2. Preserve the current SD card as a rollback copy.
3. Install the V8 kernel image, explicit Pi 2 DTB and V8 boot config.
4. Install the complete matching
   `/lib/modules/6.2.15-215.fc36.armv7hl/` directory.
5. Test boot, SD root mount, USB host, LAN9514 Ethernet, USB audio and then
   the two original Diretta modules.
6. Do not use forced module loading to bypass vermagic or unresolved symbols.
