#!/usr/bin/env bash
set -Eeuo pipefail

SRC="${1:?Usage: package-h3.sh <kernel-source-dir> <kernel-release>}"
KERNEL_RELEASE="${2:?Usage: package-h3.sh <kernel-source-dir> <kernel-release>}"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
PKG="$ROOT/package-orangepi-pc"

cd "$SRC"
ACTUAL_RELEASE="$(make -s ARCH=arm kernelrelease)"
[[ "$ACTUAL_RELEASE" == "$KERNEL_RELEASE" ]] || {
  echo "::error::Refusing to package unexpected kernel release: $ACTUAL_RELEASE"
  exit 1
}

ZIMAGE="$SRC/arch/arm/boot/zImage"
DTB="$SRC/arch/arm/boot/dts/sun8i-h3-orangepi-pc.dtb"
test -s "$ZIMAGE"
test -s "$DTB"
test -s "$SRC/Module.symvers"
test -s "$SRC/System.map"

rm -rf "$PKG"
install -d \
  "$PKG/boot/dtb/allwinner" \
  "$PKG/lib/modules" \
  "$PKG/build-info"

install -m 0644 "$ZIMAGE" "$PKG/boot/zImage"
install -m 0644 "$DTB" \
  "$PKG/boot/dtb/allwinner/sun8i-h3-orangepi-pc.dtb"

make -C "$SRC" \
  ARCH=arm \
  CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabihf-}" \
  INSTALL_MOD_PATH="$PKG" \
  modules_install

MODULE_DIR="$PKG/lib/modules/$KERNEL_RELEASE"
test -d "$MODULE_DIR"

# Install the original binary modules byte-for-byte. Never run a compiler on
# these files, strip them, patch vermagic, or force-load them.
install -d "$MODULE_DIR/extra/diretta"
install -m 0644 "$ROOT/modules/diretta/alsa_bridge.ko" \
  "$MODULE_DIR/extra/diretta/alsa_bridge.ko"
install -m 0644 "$ROOT/modules/diretta/diretta_direct.ko" \
  "$MODULE_DIR/extra/diretta/diretta_direct.ko"

rm -f "$MODULE_DIR/build" "$MODULE_DIR/source"
depmod -b "$PKG" "$KERNEL_RELEASE"

install -m 0644 "$SRC/.config" "$PKG/build-info/orangepi-pc.config"
install -m 0644 "$SRC/Module.symvers" "$PKG/build-info/Module.symvers"
install -m 0644 "$SRC/System.map" "$PKG/build-info/System.map"
install -m 0644 "$DTB" "$PKG/build-info/sun8i-h3-orangepi-pc.dtb"
install -m 0644 "$ROOT/diretta-h3-compatibility-report.txt" \
  "$PKG/build-info/diretta-compatibility-report.txt"

if [[ -f "$ROOT/.work/srpm-identification.txt" ]]; then
  install -m 0644 "$ROOT/.work/srpm-identification.txt" "$PKG/build-info/"
fi

cat > "$PKG/README-INSTALL.txt" <<EOF
Orange Pi PC / Allwinner H3 kernel package

Kernel release:
  $KERNEL_RELEASE

Files:
  boot/zImage
  boot/dtb/allwinner/sun8i-h3-orangepi-pc.dtb
  lib/modules/$KERNEL_RELEASE/
  lib/modules/$KERNEL_RELEASE/extra/diretta/alsa_bridge.ko
  lib/modules/$KERNEL_RELEASE/extra/diretta/diretta_direct.ko

Deployment strategy:
  This is a kernel/DTB/modules-only package.
  It does NOT replace U-Boot, the existing root filesystem, boot scripts,
  or the existing initramfs.

Before installation:
  1. Back up the complete boot partition and the current /lib/modules tree.
  2. Confirm the current boot configuration loads /boot/zImage and the
     sun8i-h3-orangepi-pc.dtb path shown above. Adapt file placement to the
     actual U-Boot/extlinux/Armbian boot configuration; do not blindly
     overwrite a differently named Image or DTB.
  3. The MMC controller and ext4 filesystem are built into this kernel so
     the SD-card root filesystem can mount without an initramfs.
  4. If the current boot entry explicitly loads an initramfs, inspect that
     boot entry before first boot. This package intentionally does not ship
     or replace an initramfs.
  5. Install this package's complete lib/modules/$KERNEL_RELEASE tree.

Diretta:
  The two supplied .ko files are copied unchanged from modules/diretta.
  Static checks are not proof of runtime ABI compatibility. If module load
  fails, do not force-load. Restore the previous kernel and module tree.

First boot validation:
  - uname -r must report $KERNEL_RELEASE
  - /proc/device-tree/model should identify Orange Pi PC
  - SD/MMC root, Ethernet, USB, and serial console must work
  - run depmod -a $KERNEL_RELEASE
  - load snd/snd-pcm dependencies, then test both Diretta modules
  - inspect dmesg and test sustained audio/network operation
EOF

# Ensure original modules are still byte-identical after package assembly.
cmp "$ROOT/modules/diretta/alsa_bridge.ko" \
  "$MODULE_DIR/extra/diretta/alsa_bridge.ko"
cmp "$ROOT/modules/diretta/diretta_direct.ko" \
  "$MODULE_DIR/extra/diretta/diretta_direct.ko"

(
  cd "$PKG"
  find . -type f -print0 | sort -z | xargs -0 sha256sum
) > "$PKG/SHA256SUMS"

ARCHIVE="$ROOT/orangepi-pc-h3-kernel-$KERNEL_RELEASE.tar.gz"
tar --sort=name --mtime='UTC 1970-01-01' \
  --owner=0 --group=0 --numeric-owner \
  -C "$ROOT" -cf - package-orangepi-pc | gzip -n -9 > "$ARCHIVE"
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"

echo "Package created:"
ls -lh "$ARCHIVE" "$ARCHIVE.sha256"
