# Raspberry Pi 2B Fedora 36 / Diretta Kernel V9

## Goal

Build a 32-bit ARMv7 kernel package for Raspberry Pi 2 Model B that boots the
existing Fedora 36 ext4 SD-card root and preserves compatibility requirements
of the two original, unmodified Diretta modules:

- `alsa_bridge.ko`
- `diretta_direct.ko`

Target kernel release:

`6.2.15-215.fc36.armv7hl`

Required vermagic for both original modules:

`6.2.15-215.fc36.armv7hl SMP preempt mod_unload ARMv7 p2v8`

## V9 configuration strategy

V9 deliberately changes the hardware configuration baseline from V8.

1. Start from the repository's `config/bcm2709_defconfig`.
2. Resolve it against the Fedora SRPM's Linux 6.2.15 source tree with
   `olddefconfig`; unsupported options are resolved by Kconfig.
3. Apply only `config/v9-rpi2b-diretta.fragment` for the target release,
   original Diretta ABI flags, Fedora ext4/SD direct-root boot, and required
   USB/audio support.
4. Explicitly disable unrelated desktop/server GPU, NVMe, SAS/HBA and
   foreign-architecture XZ decompressor options. Do not disable Raspberry Pi
   graphics, USB audio, USB networking, or USB storage.
5. Build `zImage`, all configured modules and the Raspberry Pi 2 DTB.

V9 does not use the Fedora kernel-devel `.config` as its hardware base.

## Diretta ABI gates

The original module files in `modules/diretta/` are checked by SHA256 and are
copied unchanged into the resulting module tree.

The build must satisfy all of these conditions:

- `CONFIG_SMP=y`
- `CONFIG_PREEMPT=y`
- `CONFIG_MODULES=y`
- `CONFIG_MODULE_UNLOAD=y`
- `CONFIG_MODVERSIONS` disabled
- `CONFIG_HIGHMEM=y`
- `CONFIG_HARDENED_USERCOPY=y`
- `CONFIG_FORTIFY_SOURCE=y`
- ARMv7 EABI and `ARM_PATCH_PHYS_VIRT` settings that produce the expected
  `ARMv7 p2v8` module architecture vermagic
- exact kernel release and exact vermagic string

The final `Module.symvers` must contain all three exact entries:

| Symbol | CRC | Export |
|---|---|---|
| `__check_object_size` | `0x00000000` | `EXPORT_SYMBOL` |
| `fortify_panic` | `0x00000000` | `EXPORT_SYMBOL` |
| `page_address` | `0x00000000` | `EXPORT_SYMBOL` |

The workflow also extracts the original
`kernel-devel-6.2.15-215.fc36.armv7hl` archive and verifies that its original
`Module.symvers` contains these same three entries. It checks every undefined
symbol imported by both original Diretta modules against the target kernel's
built-in and module export table.

These are static compatibility gates only. They cannot prove private
structure-layout compatibility or runtime correctness. Actual module loading
on the Raspberry Pi 2B remains mandatory.

## Fedora source provenance caveat

The currently available Fedora source package in the repository/release is
`kernel-6.2.15-100.fc36.src.rpm`. V9 verifies and uses its Linux 6.2.15 source,
Fedora patch, spec and `Makefile.rhelver`.

The target vermagic is set to the original
`6.2.15-215.fc36.armv7hl` because that is the release required by the supplied
Diretta modules. However, the `-100` SRPM is not the same source-package
revision as a hypothetical `-215` SRPM. The original `-215` kernel-devel
archive is used as an ABI/configuration reference, not as a replacement source
tree. Any additional Fedora patches between builds `-100` and `-215` remain
a source-provenance uncertainty until the exact `-215` SRPM is obtained.

Do not interpret a matching release string, vermagic or symbol list as proof
that the `-100` patched source is identical to the original `-215` kernel.

## Fedora 36 boot strategy

The supplied `rpi-boot/cmdline.txt` specifies an ext4 root partition by
PARTUUID. V9 therefore requires the SD/MMC controller, MMC block layer,
partition parser and ext4 filesystem to be built into the kernel.

The package contains:

- `boot/kernel7.img`
- `boot/initramfs7`
- `boot/bcm2836-rpi-2-b.dtb`
- `boot/config.txt`
- `boot/cmdline.txt`
- `lib/modules/6.2.15-215.fc36.armv7hl/`

The generated `initramfs7` is a gzip-compressed newc archive containing the
matching kernel module tree, including the two original Diretta modules, under
`/usr/lib/modules/6.2.15-215.fc36.armv7hl/`. It intentionally has no
`/init` userspace: the SD/MMC, partition and ext4 root path is built in, so
the kernel can mount the PARTUUID root directly and then execute Fedora's
userspace init from the mounted root filesystem. This design assumes the
existing Fedora root is plain ext4 on the SD card, not LUKS, LVM, RAID or a
root filesystem requiring an early userspace driver.

The generated `config.txt` explicitly selects `kernel7.img`, the Pi 2 DTB,
and `initramfs7`, while preserving the existing boot settings and overlays.
The existing `cmdline.txt` is copied unchanged; its PARTUUID must match the
actual Fedora 36 SD card.

## V9 build and test

The workflow is manual-only (`workflow_dispatch`) and does not start a build
on push. It uploads one package plus the resolved config, config delta, module
inventory, source provenance, target `Module.symvers`, original
`-215` `Module.symvers`, and Diretta compatibility report.

Acceptance order:

1. Inspect the Actions config and ABI reports.
2. Back up the current SD card.
3. Install the V9 boot files and the complete matching
   `/lib/modules/6.2.15-215.fc36.armv7hl/` directory.
4. Confirm Fedora 36 boots and the root filesystem mounts.
5. Test LAN9514/SMSC95XX Ethernet and USB audio.
6. Load both original Diretta modules without force-loading and inspect
   `dmesg`.

A successful CI build is not a successful hardware test.
