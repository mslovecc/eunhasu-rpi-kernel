#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: download-h3-v2-boot-assets.sh <uInitrd-url> <uInitrd-sha256> <DTB-url> <DTB-sha256>" >&2
  exit 2
fi

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
OUT="$ROOT/.work/original-boot"
UINITRD_URL="$1"
UINITRD_SHA256="${2,,}"
DTB_URL="$3"
DTB_SHA256="${4,,}"
mkdir -p "$OUT"

for pair in "uInitrd:$UINITRD_SHA256" "DTB:$DTB_SHA256"; do
  name="${pair%%:*}"
  hash="${pair#*:}"
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || {
    echo "::error::Invalid SHA256 for $name"
    exit 1
  }
done

fetch() {
  local url="$1" dest="$2" expected="$3"
  [[ "$url" == https://* ]] || { echo "::error::Only HTTPS asset URLs are accepted: $dest"; exit 1; }
  curl --fail --location --retry 3 --retry-all-errors --connect-timeout 20 \
    --output "$dest" "$url"
  echo "$expected  $dest" | sha256sum --check --status || {
    echo "::error::SHA256 mismatch for $dest"
    exit 1
  }
  test -s "$dest"
}

fetch "$UINITRD_URL" "$OUT/original-uInitrd" "$UINITRD_SHA256"
fetch "$DTB_URL" "$OUT/original-sun8i-h3-orangepi-pc.dtb" "$DTB_SHA256"

dumpimage -l "$OUT/original-uInitrd" | tee "$OUT/uinitrd-image-header.txt"
grep -q 'Image Type:.*RAMDisk Image' "$OUT/uinitrd-image-header.txt"
grep -q 'Architecture:.*ARM' "$OUT/uinitrd-image-header.txt"

MODEL="$(fdtget -t s "$OUT/original-sun8i-h3-orangepi-pc.dtb" / model)"
COMPAT="$(fdtget -t s "$OUT/original-sun8i-h3-orangepi-pc.dtb" / compatible)"
[[ "$MODEL" == "Xunlong Orange Pi PC" ]] || {
  echo "::error::Unexpected DTB model: $MODEL"
  exit 1
}
[[ "$COMPAT" == *"xunlong,orangepi-pc"* ]] || {
  echo "::error::Unexpected DTB compatible: $COMPAT"
  exit 1
}

PAYLOAD="$OUT/original-uInitrd.payload.gz"
dumpimage -p 0 -o "$PAYLOAD" "$OUT/original-uInitrd"
gzip -t "$PAYLOAD"
gzip -dc "$PAYLOAD" | cpio -it --quiet > "$OUT/original-initramfs-file-list.txt"
grep -qx 'init' "$OUT/original-initramfs-file-list.txt"
grep -q '^usr/lib/modules/6\.18\.35-current-sunxi/' "$OUT/original-initramfs-file-list.txt"

{
  echo "Original U-Boot uInitrd SHA256: $UINITRD_SHA256"
  echo "Original DTB SHA256: $DTB_SHA256"
  echo "DTB model: $MODEL"
  echo "DTB compatible: $COMPAT"
  echo "Original initramfs entries: $(wc -l < "$OUT/original-initramfs-file-list.txt" | tr -d ' ')"
  echo "Original initramfs module files: $(grep -c '\\.ko$' "$OUT/original-initramfs-file-list.txt" || true)"
} | tee "$OUT/original-boot-assets-report.txt"
