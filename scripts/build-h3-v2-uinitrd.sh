#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: build-h3-v2-uinitrd.sh <original-uInitrd> <package-root> <kernel-release> <output-uInitrd>" >&2
  exit 2
fi

ORIGINAL="$1"
PKG="$2"
KERNEL_RELEASE="$3"
OUTPUT="$4"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
WORK="$ROOT/.work/rebuilt-uinitrd"
PAYLOAD="$WORK/original-payload.gz"
STAGE="$WORK/root"
CPIO="$WORK/initramfs.cpio"
GZIP="$WORK/initramfs.cpio.gz"

[[ -s "$ORIGINAL" ]] || { echo "::error::Original uInitrd missing"; exit 1; }
[[ -d "$PKG/lib/modules/$KERNEL_RELEASE" ]] || {
  echo "::error::Kernel module tree missing for $KERNEL_RELEASE"
  exit 1
}
for cmd in dumpimage mkimage depmod cpio gzip modinfo; do
  command -v "$cmd" >/dev/null || { echo "::error::Missing required command: $cmd"; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$STAGE" "$WORK"

dumpimage -l "$ORIGINAL" | grep -q 'Image Type:.*RAMDisk Image'
dumpimage -p 0 -o "$PAYLOAD" "$ORIGINAL"
gzip -t "$PAYLOAD"
gzip -dc "$PAYLOAD" | (cd "$STAGE" && cpio -idm --quiet --no-absolute-filenames)

[[ -f "$STAGE/init" ]] || { echo "::error::Original initramfs /init is missing"; exit 1; }
[[ -f "$STAGE/scripts/local" && -f "$STAGE/scripts/functions" ]] || {
  echo "::error::Original initramfs-tools boot scripts are incomplete"
  exit 1
}
[[ -L "$STAGE/lib" && "$(readlink "$STAGE/lib")" == "usr/lib" ]] || {
  echo "::error::Unexpected initramfs /lib layout; refusing unsafe module replacement"
  exit 1
}

MODULES="$STAGE/usr/lib/modules"
mkdir -p "$MODULES"
find "$MODULES" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
cp -a "$PKG/lib/modules/$KERNEL_RELEASE" "$MODULES/$KERNEL_RELEASE"

# /lib is the original symlink to /usr/lib, so depmod writes the expected tree.
depmod -b "$STAGE" "$KERNEL_RELEASE"

NEW_MODULE_DIR="$MODULES/$KERNEL_RELEASE"
[[ -s "$NEW_MODULE_DIR/modules.dep" ]] || {
  echo "::error::depmod did not create modules.dep in rebuilt initramfs"
  exit 1
}
[[ -n "$(find "$NEW_MODULE_DIR" -type f -name '*.ko' -print -quit)" ]] || {
  echo "::error::No kernel modules found in rebuilt initramfs"
  exit 1
}

CONFIG="$PKG/build-info/orangepi-pc.config"
for sym in CONFIG_MMC CONFIG_MMC_SUNXI CONFIG_EXT4_FS CONFIG_DEVTMPFS; do
  if ! grep -Eq "^$sym=y$|^$sym=m$" "$CONFIG"; then
    echo "::error::Required early-boot kernel option is absent: $sym"
    exit 1
  fi
done

(
  cd "$STAGE"
  find . -print0 | LC_ALL=C sort -z | cpio --null -o -H newc --reproducible --quiet
) > "$CPIO"
gzip -n -9 -c "$CPIO" > "$GZIP"
mkdir -p "$(dirname "$OUTPUT")"
mkimage -A arm -O linux -T ramdisk -C gzip \
  -n "Eunhasu H3 initramfs" \
  -d "$GZIP" "$OUTPUT"

dumpimage -l "$OUTPUT" > "$WORK/new-uinitrd-header.txt"
grep -q 'Image Type:.*RAMDisk Image' "$WORK/new-uinitrd-header.txt"
grep -q 'Architecture:.*ARM' "$WORK/new-uinitrd-header.txt"
dumpimage -p 0 -o "$WORK/check.gz" "$OUTPUT"
gzip -t "$WORK/check.gz"
gzip -dc "$WORK/check.gz" | cpio -it --quiet > "$WORK/new-file-list.txt"
grep -qx 'init' "$WORK/new-file-list.txt"
grep -q "^usr/lib/modules/$KERNEL_RELEASE/" "$WORK/new-file-list.txt"

KO="$(find "$NEW_MODULE_DIR" -type f -name '*.ko' -print -quit)"
VM="$(modinfo -F vermagic "$KO" | xargs)"
[[ "$VM" == "$KERNEL_RELEASE"* ]] || {
  echo "::error::Initramfs module vermagic does not match kernel release: $VM"
  exit 1
}

{
  echo "Original uInitrd SHA256: $(sha256sum "$ORIGINAL" | awk '{print $1}')"
  echo "New uInitrd SHA256: $(sha256sum "$OUTPUT" | awk '{print $1}')"
  echo "Kernel release: $KERNEL_RELEASE"
  echo "Module files in initramfs: $(find "$NEW_MODULE_DIR" -type f -name '*.ko' | wc -l | tr -d ' ')"
  echo "Module tree size: $(du -sh "$NEW_MODULE_DIR" | awk '{print $1}')"
  echo "Compressed initramfs payload: $(stat -c '%s' "$GZIP") bytes"
  echo "U-Boot uInitrd: $(stat -c '%s' "$OUTPUT") bytes"
  echo "Module vermagic sample: $VM"
} | tee "$PKG/build-info/uinitrd-build-report.txt"
