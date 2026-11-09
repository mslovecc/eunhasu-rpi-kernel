# Orange Pi PC / Allwinner H3 kernel build

This is a separate first-stage build path. It does not modify the Raspberry Pi 2
workflow `.github/workflows/build_v4.yml`.

## Target and fixed baseline

- Board: Orange Pi PC (Allwinner H3 / sun8i-h3)
- Architecture: 32-bit ARM, `ARCH=arm`, ARMv7
- Kernel source: Linux 6.2.15
- Fedora source package: `kernel-6.2.15-100.fc36.src.rpm`
- Target kernel release: `6.2.15-215.fc36.armv7hl`
- DTB: `sun8i-h3-orangepi-pc.dtb`
- Diretta modules: original repository v4 `alsa_bridge.ko` and `diretta_direct.ko`; never rebuilt or modified

## Configuration design

The base is the repository's Fedora `kernel-armv7hl-fedora.config`, not a
fresh minimal `sunxi_defconfig`. That Fedora ARMv7 config already enables
Allwinner sunxi / sun8i support and is a closer configuration baseline for
the existing Fedora-built binary modules.

The following fragments are merged over it:

- `config/h3-orangepi-pc.fragment`: board boot-critical SD/MMC, ext4, UART,
  Ethernet, USB, pinctrl and regulator settings.
- `config/h3-diretta.fragment`: ARMv7, preemption, module and ALSA settings
  retained from the known v4 module setup.

The workflow runs `olddefconfig` and then verifies that required settings
survive Kconfig dependency resolution. A missing required option is a hard
failure rather than silently accepting a different configuration.

## Source download order

1. A matching file in `sources/dist/` in the checked-out repository.
2. The raw GitHub file at the current workflow ref under `sources/dist/`.
3. The configured fallback mirror `https://s2.bravo123.top`.

Every candidate must match the SHA256 values already used by the v4 build.
The SRPM identity, extracted spec, patch, Fedora config and Makefile.rhelver
are also compared against the checked-in support files.

## Package contents and installation boundary

The artifact contains:

- `boot/zImage`
- `boot/dtb/allwinner/sun8i-h3-orangepi-pc.dtb`
- `lib/modules/6.2.15-215.fc36.armv7hl/`
- the two original Diretta modules under `extra/diretta/`
- config, Module.symvers, System.map and a compatibility report

It intentionally does not contain or replace U-Boot, rootfs, boot scripts or
initramfs. Before deployment, back up the SD card and inspect the actual
U-Boot/extlinux/Armbian boot entry to confirm its kernel, DTB and initramfs
paths. Do not blindly overwrite a differently named kernel image or DTB.

MMC/SD and ext4 are built into the kernel to allow mounting an SD-card root
filesystem without relying on old initramfs modules. If the current boot entry
loads an initramfs, inspect that boot entry before first boot; this artifact
does not regenerate an initramfs.

## Diretta compatibility limits

The build verifies:

- exact original module vermagic against the target kernel release string;
- ELF32 / ARM architecture;
- dependency metadata;
- byte-for-byte preservation of both supplied KO files;
- presence of each imported symbol name in the new kernel's Module.symvers.

The Fedora ARMv7 baseline and v4 fragment disable `CONFIG_MODVERSIONS`.
Consequently this workflow does not claim symbol-CRC compatibility. Even a
complete symbol-name match cannot prove structure layout, calling convention,
locking or runtime ABI compatibility.

Do not use `insmod -f`, `modprobe --force`, or vermagic patching. The final
acceptance test must be performed on the actual Orange Pi PC:

1. Boot and verify `uname -r` is `6.2.15-215.fc36.armv7hl`.
2. Verify `/proc/device-tree/model` identifies Orange Pi PC.
3. Verify SD/MMC root, Ethernet, USB and serial console.
4. Run `depmod -a 6.2.15-215.fc36.armv7hl`.
5. Load ALSA dependencies and both original Diretta modules.
6. Check `dmesg` and exercise Diretta audio/network operation.

If either KO fails to load, preserve the logs and restore the previous kernel
and module tree. Do not force-load it.
