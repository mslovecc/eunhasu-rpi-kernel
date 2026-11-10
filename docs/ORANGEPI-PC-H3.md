# Orange Pi PC / Allwinner H3 kernel build (V2)

This is a separate H3 build path. It does not modify the Raspberry Pi 2
workflow `.github/workflows/build_v4.yml`.

## Fixed target

- Board: Xunlong Orange Pi PC / Allwinner H3
- Architecture: 32-bit ARMv7 (`ARCH=arm`)
- Kernel source: Linux 6.2.15 plus the checked-in Fedora 6.2.15 SRPM patch
- Kernel release: `6.2.15-215.fc36.armv7hl`
- Diretta modules: original `alsa_bridge.ko` and `diretta_direct.ko`; copied byte-for-byte and never stripped
- Original boot baseline: verified Eunhasu `uInitrd` and Release DTB; the Release DTB is retained as a reference; the active DTB is built from Linux 6.2.15 source

## Original boot assets are workflow inputs

The original uInitrd is downloaded directly from the repository's `6.2.15`
GitHub Release by default:

- URL: `https://github.com/mslovecc/eunhasu-rpi-kernel/releases/download/6.2.15/uInitrd`
- SHA256: `7273d8d0868402c31f2aa380304c5d67bd6183028d193624a72dbea46b1cddbe`

The Release also contains an original `zImage`. V2 deliberately builds a fresh
zImage and the matching kernel modules from the same Linux 6.2.15 source tree
and effective Armbian-derived configuration; it does not mix the Release
zImage with modules from a separate build.

The Release DTB is downloaded and SHA256-verified, then checked for the
Orange Pi PC model and compatible string. The workflow also builds a DTB
from the exact Linux 6.2.15 source tree and compares the normalized DTS
representations for diagnostics. The Release DTB differs from the 6.2.15
source-built tree, so it is retained only as a reference in build-info.
The active boot DTB is the one built alongside zImage from the same source
tree; this avoids mixing a newer or differently configured device tree with
the 6.2.15 kernel.

The uInitrd and DTB URLs/checksums remain overridable through workflow_dispatch.
The workflow verifies the uInitrd checksum, U-Boot RAMDisk header, gzip payload
and initramfs cpio structure, and checks the DTB's Orange Pi PC model and
compatible string.

## Configuration and size controls

The build starts from the Armbian 6.18.35 sunxi config, adapts it to Linux
6.2.15, then checks the effective Kconfig result.

- Debug information and BTF are explicitly disabled and verified after
  `olddefconfig`.
- `modules_install` uses `INSTALL_MOD_STRIP=1` to strip debug sections from
  newly built kernel modules.
- The two supplied Diretta modules are copied after stripping and checked
  byte-for-byte against their originals.
- The package reports zImage, DTB, uInitrd, module count, module-tree size,
  largest modules and archive size.

## Initramfs construction

V2 preserves Eunhasu's original initramfs-tools userspace and replaces only
the old module directory:

1. Extract the verified original U-Boot `uInitrd` payload.
2. Preserve `/init`, initramfs-tools scripts, udev, binaries, configuration,
   symlinks and all other original files.
3. Replace `/usr/lib/modules/6.18.35-current-sunxi` with the complete module
   tree built for `6.2.15-215.fc36.armv7hl`.
4. Regenerate module dependency indexes with `depmod`.
5. Repack as newc cpio + gzip and wrap with `mkimage` as an ARM/Linux U-Boot
   RAMDisk image.
6. Verify U-Boot header, gzip payload, cpio contents, module directory and
   sample module vermagic.

The V2 zImage and modules are built from one selected Linux source/configuration.
The source-built DTB is the active boot DTB. The Release DTB is retained as
a reference file and the DTS difference report is included in build-info. The original Eunhasu uInitrd userspace is preserved, with
its module tree rebuilt for the new kernel. This keeps the kernel, DTB and
initramfs module tree aligned while retaining the existing Eunhasu boot logic.

## Deployment boundary

The artifact contains `boot/zImage`, `boot/uInitrd`,
`boot/dtb/allwinner/sun8i-h3-orangepi-pc.dtb`, the complete
`lib/modules/6.2.15-215.fc36.armv7hl/` tree and build/audit reports.

Back up the entire boot media before deployment. Confirm the current U-Boot
environment loads the same kernel, initrd and DTB paths. Use `bootz` for this
native ARM zImage + initrd + DTB arrangement; do not blindly copy example
load addresses. Preserve the old boot triplet and module tree for rollback.

## Diretta compatibility limits

The workflow verifies kernelrelease/vermagic, ELF32/ARM identity, dependencies,
selected symbol names, and exact preservation of both supplied KO files.
`CONFIG_MODVERSIONS` remains disabled; static symbol checks do not prove
structure-layout or runtime ABI compatibility. Never force-load or patch vermagic.

Final acceptance must happen on the actual Orange Pi PC: boot, check
`uname -r`, model, MMC/root mount, Ethernet, USB, serial console, ALSA and
Diretta operation. If a module fails to load, retain logs and roll back.
