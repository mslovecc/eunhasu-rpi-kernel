# V10 — Raspberry Pi 2B Fedora 36 kernel with Diretta modules

## Source and configuration
- Repository: https://github.com/raspberrypi/linux
- Branch: rpi-6.2.y
- Pinned commit: 4c7938b86db7dfccbfd4d2a840091cbb7fbf2e9f
- Actual upstream source version: Linux 6.2.16
- Hardware base: upstream arch/arm/configs/bcm2709_defconfig
- Additional settings: config/v10-rpi2b-diretta.fragment

The source commit is pinned so that a later movement of rpi-6.2.y cannot
silently change the build input.

## Deliberate release spoof
The supplied original Diretta modules require:
6.2.15-215.fc36.armv7hl SMP preempt mod_unload ARMv7 p2v8

V10 builds the 6.2.16 source but changes the source Makefile SUBLEVEL from
16 to 15 before configuration/build, and sets CONFIG_LOCALVERSION to
-215.fc36.armv7hl. The resulting kernel release and module vermagic must
match the original string exactly. Provenance records the actual source
commit and actual upstream version separately.

This is a release-identity spoof, not a claim that upstream 6.2.16 source is
identical to Fedora's 6.2.15-215 source.

## Required module ABI settings
- CONFIG_SMP=y
- CONFIG_PREEMPT=y (not PREEMPT_RT)
- CONFIG_MODULES=y
- CONFIG_MODULE_UNLOAD=y
- CONFIG_MODVERSIONS disabled
- ARMv7 EABI and ARM_PATCH_PHYS_VIRT to produce ARMv7 p2v8
- no forced module-signature enforcement

The build verifies both original KO files' SHA256 and exact vermagic. It
extracts undefined and defined symbols from both modules, resolves imports
against the kernel Module.symvers and the combined exports of both Diretta
modules, and requires these exact kernel exports:
- __check_object_size, CRC 0x00000000, EXPORT_SYMBOL
- fortify_panic, CRC 0x00000000, EXPORT_SYMBOL
- page_address, CRC 0x00000000, EXPORT_SYMBOL

Symbol-name checks do not guarantee compatibility of private structure
layouts or runtime behavior. Hardware module-load tests remain mandatory.

## Fedora 36 boot/package
The artifact includes kernel7.img, initramfs7, bcm2836-rpi-2-b.dtb,
config.txt, cmdline.txt and the complete matching
lib/modules/6.2.15-215.fc36.armv7hl tree. SD/MMC, partition parsing and ext4
are required built-in so the existing Fedora root=PARTUUID ext4 root can mount
without an early userspace driver. The initramfs is a gzip newc archive
containing the matching module tree and the two unchanged Diretta modules.

## Acceptance
1. Inspect source provenance, final config, exact vermagic and symbol report.
2. Back up the Fedora 36 SD card.
3. Install boot files and matching /lib/modules tree.
4. Verify Raspberry Pi 2B boots and mounts Fedora root.
5. Verify LAN9514 Ethernet and USB audio.
6. Load both original Diretta modules without force-loading and inspect dmesg.

CI success is not a substitute for a real Raspberry Pi 2B boot and module test.
