#!/usr/bin/env bash
set -Eeuo pipefail

SRC="${1:?Usage: verify-rpi2b-boot-chain.sh <kernel-source-dir> <initramfs> <report>}"
INITRAMFS="${2:?Usage: verify-rpi2b-boot-chain.sh <kernel-source-dir> <initramfs> <report>}"
REPORT="${3:?Usage: verify-rpi2b-boot-chain.sh <kernel-source-dir> <initramfs> <report>}"

fail() { echo "::error::$*" | tee -a "$REPORT" >&2; exit 1; }
mkdir -p "$(dirname "$REPORT")"
: > "$REPORT"
exec > >(tee -a "$REPORT") 2>&1

echo "Raspberry Pi 2B early boot / root mount audit"
echo "Kernel config: $SRC/.config"
echo "Initramfs: $INITRAMFS"
test -s "$SRC/.config" || fail "Missing final kernel .config"
test -s "$INITRAMFS" || fail "Missing original Eunhasu initramfs7"

require_y() {
  grep -qx "CONFIG_$1=y" "$SRC/.config" || fail "CONFIG_$1 must be built-in (=y)"
  echo "PASS: CONFIG_$1=y"
}

echo
echo "[Root-storage and filesystem drivers must be built-in]"
for c in MMC MMC_BLOCK MMC_BCM2835 MMC_SDHCI MMC_SDHCI_PLTFM MMC_SDHCI_IPROC EXT4_FS MSDOS_PARTITION; do
  require_y "$c"
done

echo
echo "[Initramfs and device-node support]"
for c in BLK_DEV_INITRD DEVTMPFS DEVTMPFS_MOUNT; do
  require_y "$c"
done

echo
echo "[Reject modular root-critical drivers]"
for c in MMC_BCM2835 MMC_SDHCI_IPROC EXT4_FS MSDOS_PARTITION; do
  if grep -qx "CONFIG_$c=m" "$SRC/.config"; then
    fail "Root-critical CONFIG_$c is modular"
  fi
done

echo
echo "[Inspect original initramfs contents without modifying it]"
file "$INITRAMFS"
LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT
if gzip -t "$INITRAMFS" 2>/dev/null; then
  gzip -dc "$INITRAMFS" | cpio -it --quiet > "$LIST"
elif xz -t "$INITRAMFS" 2>/dev/null; then
  xz -dc "$INITRAMFS" | cpio -it --quiet > "$LIST"
else
  cpio -it --quiet < "$INITRAMFS" > "$LIST"
fi
COUNT="$(wc -l < "$LIST")"
echo "Initramfs entries: $COUNT"
grep -E '(^|/)(init|linuxrc)$' "$LIST" || true
if grep -Eq '(^|/)(init|linuxrc)$' "$LIST"; then
  echo "Early userspace entry exists; its script and dependencies require separate review."
else
  echo "No /init or linuxrc entry found."
  echo "The kernel is expected to continue with normal root-device discovery and mount."
  echo "The old embedded module directory is not treated as a replacement for the matching kernel module tree."
fi
grep -E '(^|/)lib/modules/[^/]+/' "$LIST" | sed -E 's#.*lib/modules/([^/]+)/.*#Embedded module release: \1#' | sort -u || true

echo
echo "[Required Pi 2B SD host objects]"
test -s "$SRC/drivers/mmc/host/bcm2835.o" || fail "BCM2835 SDHOST object missing"
test -s "$SRC/drivers/mmc/host/sdhci-iproc.o" || fail "SDHCI iProc object missing"
echo "PASS: both SD host drivers were built into the kernel"

echo
echo "BOOT CHAIN STATIC AUDIT PASSED."
echo "This cannot verify the physical SD card, boot firmware settings, root PARTUUID or runtime mount."
