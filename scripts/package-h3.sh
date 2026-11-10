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
BUILT_DTB="$SRC/arch/arm/boot/dts/sun8i-h3-orangepi-pc.dtb"
test -s "$ZIMAGE"
test -s "$BUILT_DTB"
test -s "$ORIGINAL_DTB"
test -s "$ORIGINAL_UINITRD"

# Keep the Release DTB as a reference, but do not deploy it: its
# normalized device-tree source differs from the Linux 6.2.15 source tree.
# The active boot DTB is always built alongside this kernel's zImage.
DTC="$SRC/scripts/dtc/dtc"
test -x "$DTC"
mkdir -p "$ROOT/.work/dtb-compare"
"$DTC" -I dtb -O dts -s -o "$ROOT/.work/dtb-compare/source.dts" "$BUILT_DTB"
"$DTC" -I dtb -O dts -s -o "$ROOT/.work/dtb-compare/release.dts" "$ORIGINAL_DTB"
if cmp -s "$ROOT/.work/dtb-compare/source.dts" "$ROOT/.work/dtb-compare/release.dts"; then
  DTB_CONTENT_MATCH="identical"
  : > "$ROOT/.work/dtb-compare/release-vs-source.diff"
else
  DTB_CONTENT_MATCH="different"
  diff -u "$ROOT/.work/dtb-compare/source.dts" "$ROOT/.work/dtb-compare/release.dts" \
    > "$ROOT/.work/dtb-compare/release-vs-source.diff" || true
fi
test -s "$SRC/Module.symvers"
test -s "$SRC/System.map"

if grep -Eq '^CONFIG_DEBUG_INFO=y$|^CONFIG_DEBUG_INFO_BTF=y$|^CONFIG_DEBUG_INFO_BTF_MODULES=y$' "$SRC/.config"; then
  echo "::error::DEBUG_INFO/BTF must be disabled for the production H3 V2 build"
  exit 1
fi

BUILT_MODEL="$(fdtget -t s "$BUILT_DTB" / model)"
BUILT_COMPAT="$(fdtget -t s "$BUILT_DTB" / compatible)"
RELEASE_MODEL="$(fdtget -t s "$ORIGINAL_DTB" / model)"
RELEASE_COMPAT="$(fdtget -t s "$ORIGINAL_DTB" / compatible)"
[[ "$BUILT_MODEL" == "Xunlong Orange Pi PC" && "$BUILT_COMPAT" == *"xunlong,orangepi-pc"* ]] || {
  echo "::error::Source-built DTB does not identify Orange Pi PC: $BUILT_MODEL / $BUILT_COMPAT"
  exit 1
}
[[ "$RELEASE_MODEL" == "Xunlong Orange Pi PC" && "$RELEASE_COMPAT" == *"xunlong,orangepi-pc"* ]] || {
  echo "::error::Release reference DTB does not identify Orange Pi PC: $RELEASE_MODEL / $RELEASE_COMPAT"
  exit 1
}

rm -rf "$PKG"
install -d "$PKG/boot/dtb/allwinner" "$PKG/lib/modules" "$PKG/build-info"
install -m 0644 "$ZIMAGE" "$PKG/boot/zImage"
install -m 0644 "$BUILT_DTB" "$PKG/boot/dtb/allwinner/sun8i-h3-orangepi-pc.dtb"

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
install -m 0644 "$BUILT_DTB" "$PKG/build-info/sun8i-h3-orangepi-pc.dtb"
install -m 0644 "$ORIGINAL_DTB" "$PKG/build-info/release-reference-sun8i-h3-orangepi-pc.dtb"
install -m 0644 "$ROOT/.work/dtb-compare/source.dts" "$PKG/build-info/dtb-source.dts"
install -m 0644 "$ROOT/.work/dtb-compare/release.dts" "$PKG/build-info/dtb-release-reference.dts"
install -m 0644 "$ROOT/.work/dtb-compare/release-vs-source.diff" "$PKG/build-info/dtb-release-vs-source.diff"
{
  echo "DTB comparison: $DTB_CONTENT_MATCH"
  echo "Active boot DTB source: Linux $KERNEL_RELEASE build tree"
  echo "Active boot DTB SHA256: $(sha256sum "$BUILT_DTB" | awk '{print $1}')"
  echo "Release reference DTB SHA256: $(sha256sum "$ORIGINAL_DTB" | awk '{print $1}')"
  echo "Normalized source DTS SHA256: $(sha256sum "$ROOT/.work/dtb-compare/source.dts" | awk '{print $1}')"
  echo "Normalized Release DTS SHA256: $(sha256sum "$ROOT/.work/dtb-compare/release.dts" | awk '{print $1}')"
} > "$PKG/build-info/dtb-source-comparison.txt"
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
  echo "Active source-built DTB bytes: $(stat -c '%s' "$PKG/boot/dtb/allwinner/sun8i-h3-orangepi-pc.dtb")"
  echo "Active source-built DTB SHA256: $(sha256sum "$BUILT_DTB" | awk '{print $1}')"
  echo "Release reference DTB SHA256: $(sha256sum "$ORIGINAL_DTB" | awk '{print $1}')"
  echo "Normalized Release/source DTB contents: $DTB_CONTENT_MATCH"
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
  - Active DTB is built from the same Linux 6.2.15 source tree as zImage.
  - The Release DTB is retained under build-info as a reference only because
    its normalized device-tree content differs from the source-built DTB.
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
