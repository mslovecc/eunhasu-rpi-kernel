#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: download-h3-v2-boot-assets.sh <uInitrd-url> <uInitrd-sha256>" >&2
  exit 2
fi

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
OUT="$ROOT/.work/original-boot"
UINITRD_URL="$1"
UINITRD_SHA256="${2,,}"
mkdir -p "$OUT"

[[ "$UINITRD_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "::error::Invalid SHA256 for original uInitrd"
  exit 1
}
[[ "$UINITRD_URL" == https://* ]] || {
  echo "::error::Only HTTPS asset URLs are accepted"
  exit 1
}

curl --fail --location --retry 3 --retry-all-errors --connect-timeout 20 \
  --output "$OUT/original-uInitrd" "$UINITRD_URL"

echo "$UINITRD_SHA256  $OUT/original-uInitrd" | sha256sum --check --status || {
  echo "::error::Original uInitrd SHA256 mismatch"
  exit 1
}
test -s "$OUT/original-uInitrd"

dumpimage -l "$OUT/original-uInitrd" | tee "$OUT/uinitrd-image-header.txt"
grep -q 'Image Type:.*RAMDisk Image' "$OUT/uinitrd-image-header.txt"
grep -q 'Architecture:.*ARM' "$OUT/uinitrd-image-header.txt"

PAYLOAD="$OUT/original-uInitrd.payload.gz"
dumpimage -p 0 -o "$PAYLOAD" "$OUT/original-uInitrd"
gzip -t "$PAYLOAD"
gzip -dc "$PAYLOAD" | cpio -it --quiet > "$OUT/original-initramfs-file-list.txt"
grep -qx 'init' "$OUT/original-initramfs-file-list.txt"

{
  echo "Original U-Boot uInitrd SHA256: $UINITRD_SHA256"
  echo "Original uInitrd bytes: $(stat -c '%s' "$OUT/original-uInitrd")"
  echo "Original initramfs entries: $(wc -l < "$OUT/original-initramfs-file-list.txt" | tr -d ' ')"
  echo "Original initramfs module files: $(grep -c 'ko$' "$OUT/original-initramfs-file-list.txt" || true)"
  echo "U-Boot image header: ARM/Linux RAMDisk"
} | tee "$OUT/original-boot-assets-report.txt"
