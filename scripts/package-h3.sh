#!/usr/bin/env bash
set -Eeuo pipefail

SRC="${1:?Usage: package-h3.sh <kernel-source-dir> <kernel-release>}"
KERNEL_RELEASE="${2:?Usage: package-h3.sh <kernel-source-dir> <kernel-release>}"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
PKG="$ROOT/package-orangepi-pc"
ORIGINAL_DTB="${ORIGINAL_DTB:?ORIGINAL_DTB must point to the verified original Orange Pi PC DTB}"
ORIGINAL_UINITRD="${ORIGINAL_UINITRD:?ORIGINAL_UINITRD must point to the verified original Eunhasu uInitrd}"

cd "$SRC"
ACTUAL_RELEASE="$(make -s ARCH=arm kernelrelease)"
[[ "$ACTUAL_RELEASE" == "$KERNEL_RELEASE" ]] || {
  echo "::error::Refusing to package unexpected kernel release: $ACTUAL_RELEASE"
  exit 1
}

ZIMAGE="$SRC/arch/arm/boot/zImage"
test -s "$ZIMAGE"
test -s "$ORIGINAL_DTB"
test -s "$ORIGINAL_UINITRD"
test -s "$SRC/Module.symvers"
test -s "$SRC/System.map"

if grep -Eq '^CONFIG_DEBUG_INFO=y$|^CONFIG_DEBUG_INFO_BTF=y$|^CONFIG_DEBUG_INFO_BTF_MODULES=y$' "$SRC/.config"; then
  echo "::error::DEBUG_INFO/BTF must be disabled for the production H3 V2 build"
  exit 1
fi

MODEL="$(fdtget -t s "$ORIGINAL_DTB" / model)"
COMPAT="$(fdtget -t s "$ORIGINAL_DTB" / compatible)"
[[ "$MODEL" == "Xunlong Orange Pi PC" && "$COMPAT" == *"xunlong,orangepi-pc"* ]] || {
  echo "::error::Original DTB does not identify Orange Pi PC: $MODEL / $COMPAT"
  exit 1
}

rm -rf "$PKG"
install -d "$PKG/boot/dtb/allwinner" "$PKG/lib/modules" "$PKG/build-info"
install -m 0644 "$ZIMAGE" "$PKG/boot/zImage"
install -m 0644 "$ORIGINAL_DTB" "$PKG/boot/dtb/allwinner/sun8i-h3-orangepi-pc.dtb"

# Strip debug sections from newly built kernel modules only.
make -C "$SRC" \
  ARCH=arm \
  CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabihf-}" \
  INSTALL_MOD_PATH="$PKG" \
  INSTALL_MOD_STRIP=1 \
  modules_install

MODULE_DIR="$PKG/lib/modules/$KERNEL_RELEASE"
test -d "$MODULE_DIR"
install -d "$MODULE_DIR/extra/diretta"
install -m 0644 "$ROOT/modules/diretta/alsa_bridge.ko" "$MODULE_DIR/extra/diretta/alsa_bridge.ko"
install -m 0644 "$ROOT/modules/diretta/diretta_direct.ko" "$MODULE_DIR/extra/diretta/diretta_direct.ko"
rm -f "$MODULE_DIR/build" "$MODULE_DIR/source"
depmod -b "$PKG" "$KERNEL_RELEASE"

install -m 0644 "$SRC/.config" "$PKG/build-info/orangepi-pc.config"
install -m 0644 "$SRC/Module.symvers" "$PKG/build-info/Module.symvers"
install -m 0644 "$SRC/System.map" "$PKG/build-info/System.map"
install -m 0644 "$ORIGINAL_DTB" "$PKG/build-info/sun8i-h3-orangepi-pc.dtb"
if [[ -f "$ROOT/.work/srpm-identification.txt" ]]; then
  install -m 0644 "$ROOT/.work/srpm-identification.txt" "$PKG/build-info/"
fi

bash "$ROOT/scripts/build-h3-v2-uinitrd.sh" \
  "$ORIGINAL_UINITRD" "$PKG" "$KERNEL_RELEASE" "$PKG/boot/uInitrd"

for name in alsa_bridge.ko diretta_direct.ko; do
  cmp "$ROOT/modules/diretta/$name" "$MODULE_DIR/extra/diretta/$name"
done

MODULE_COUNT="$(find "$MODULE_DIR" -type f -name '*.ko' | wc -l | tr -d ' ')"
MODULE_BYTES="$(du -sb "$MODULE_DIR" | awk '{print $1}')"
{
  echo "Orange Pi PC / H3 production package report"
  echo "Kernel release: $KERNEL_RELEASE"
  echo "zImage bytes: $(stat -c '%s' "$PKG/boot/zImage")"
  echo "Built H3 DTB bytes: $(stat -c '%s' "$PKG/boot/dtb/allwinner/sun8i-h3-orangepi-pc.dtb")"
  echo "Rebuilt uInitrd bytes: $(stat -c '%s' "$PKG/boot/uInitrd")"
  echo "Installed module count: $MODULE_COUNT"
  echo "Installed module tree bytes: $MODULE_BYTES"
  echo "Installed module tree human size: $(du -sh "$MODULE_DIR" | awk '{print $1}')"
  echo
  echo "[Largest 20 modules]"
  find "$MODULE_DIR" -type f -name '*.ko' -printf '%s %p\n' | sort -nr | head -20
  echo
  echo "[Diretta SHA256]"
  sha256sum "$MODULE_DIR/extra/diretta/alsa_bridge.ko" "$MODULE_DIR/extra/diretta/diretta_direct.ko"
} | tee "$PKG/build-info/package-size-report.txt"

cat > "$PKG/README-INSTALL.txt" <<EOF
Orange Pi PC / Allwinner H3 Eunhasu kernel package
Kernel release: $KERNEL_RELEASE

Files:
  boot/zImage
  boot/uInitrd
  boot/dtb/allwinner/sun8i-h3-orangepi-pc.dtb
  lib/modules/$KERNEL_RELEASE/

Boot asset strategy:
  - zImage is built by this V2 workflow.
  - DTB is the byte-identical original Eunhasu Orange Pi PC DTB.
  - uInitrd retains original initramfs-tools scripts, udev, binaries and
    configuration. Only the old 6.18.35 module directory is replaced with
    this build's $KERNEL_RELEASE modules; depmod indexes are regenerated.
  - Verify current U-Boot paths, boot arguments and load addresses. Use bootz
    for zImage + initrd + DTB; do not copy example addresses blindly.

Deployment:
  1. Back up the complete boot media and old module tree.
  2. Install the three boot files at the paths used by current U-Boot setup.
  3. Install the complete lib/modules/$KERNEL_RELEASE tree.
  4. Keep the previous boot triplet and module tree for rollback.

Diretta:
  Original Diretta .ko files are copied byte-for-byte and never stripped.
  Static checks do not prove runtime ABI compatibility. Never force-load.
EOF

(
  cd "$PKG"
  find . -type f -print0 | sort -z | xargs -0 sha256sum
) > "$PKG/SHA256SUMS"

ARCHIVE="$ROOT/orangepi-pc-h3-kernel-$KERNEL_RELEASE.tar.gz"
tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
  -C "$ROOT" -cf - package-orangepi-pc | gzip -n -9 > "$ARCHIVE"
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
echo "Package created:"
ls -lh "$ARCHIVE" "$ARCHIVE.sha256"
