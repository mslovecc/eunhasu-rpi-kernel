#!/usr/bin/env bash
# Verify the Release boot assets before any kernel compilation is allowed to start.
set -Eeuo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: download-h3-v2-boot-assets.sh <uInitrd-url> <uInitrd-sha256> <dtb-url> <dtb-sha256>" >&2
  exit 2
fi

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
OUT="$ROOT/.work/original-boot"
UINITRD_URL="$1"
UINITRD_SHA256="${2,,}"
DTB_URL="$3"
DTB_SHA256="${4,,}"
mkdir -p "$OUT"

validate_https() {
  local url="$1" label="$2"
  [[ "$url" == https://* ]] || {
    echo "::error::$label URL must use HTTPS"
    exit 1
  }
}
validate_sha256() {
  local value="$1" label="$2"
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] || {
    echo "::error::Invalid SHA256 for $label"
    exit 1
  }
}
download_and_verify() {
  local url="$1" sha="$2" destination="$3" label="$4"
  curl --fail --location --retry 3 --retry-all-errors --connect-timeout 20 \
    --output "$destination" "$url"
  echo "$sha  $destination" | sha256sum --check --status || {
    echo "::error::$label SHA256 mismatch"
    exit 1
  }
  test -s "$destination"
}

validate_https "$UINITRD_URL" "uInitrd"
validate_https "$DTB_URL" "DTB"
validate_sha256 "$UINITRD_SHA256" "uInitrd"
validate_sha256 "$DTB_SHA256" "DTB"

download_and_verify "$UINITRD_URL" "$UINITRD_SHA256" "$OUT/original-uInitrd" "Original uInitrd"
download_and_verify "$DTB_URL" "$DTB_SHA256" "$OUT/original-sun8i-h3-orangepi-pc.dtb" "Release DTB"

dumpimage -l "$OUT/original-uInitrd" | tee "$OUT/uinitrd-image-header.txt"
grep -Eq 'Image Type:.*ARM Linux RAMDisk Image' "$OUT/uinitrd-image-header.txt"

PAYLOAD="$OUT/original-uInitrd.payload.gz"
dumpimage -p 0 -o "$PAYLOAD" "$OUT/original-uInitrd"
gzip -t "$PAYLOAD"
gzip -dc "$PAYLOAD" | cpio -it --quiet > "$OUT/original-initramfs-file-list.txt"
grep -Eq '^(\./)?init$' "$OUT/original-initramfs-file-list.txt" || {
  echo "::error::Original initramfs does not contain /init"
  exit 1
}

MODEL="$(fdtget -t s "$OUT/original-sun8i-h3-orangepi-pc.dtb" / model)"
COMPAT="$(fdtget -t s "$OUT/original-sun8i-h3-orangepi-pc.dtb" / compatible)"
[[ "$MODEL" == "Xunlong Orange Pi PC" && "$COMPAT" == *"xunlong,orangepi-pc"* ]] || {
  echo "::error::Release DTB is not for Orange Pi PC: $MODEL / $COMPAT"
  exit 1
}

{
  echo "Original U-Boot uInitrd SHA256: $UINITRD_SHA256"
  echo "Original uInitrd bytes: $(stat -c '%s' "$OUT/original-uInitrd")"
  echo "Original initramfs entries: $(wc -l < "$OUT/original-initramfs-file-list.txt" | tr -d ' ')"
  echo "Original initramfs module files: $(grep -c 'ko$' "$OUT/original-initramfs-file-list.txt" || true)"
  echo "Release DTB SHA256: $DTB_SHA256"
  echo "Release DTB bytes: $(stat -c '%s' "$OUT/original-sun8i-h3-orangepi-pc.dtb")"
  echo "Release DTB model: $MODEL"
  echo "Release DTB compatible: $COMPAT"
  echo "U-Boot image header: ARM/Linux RAMDisk"
} | tee "$OUT/original-boot-assets-report.txt"
