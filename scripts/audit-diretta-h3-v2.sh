#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: audit-diretta-h3-v2.sh <kernel-source-dir> <package-root>" >&2
  exit 2
fi

SRC="$1"
PKG="$2"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
EXPECTED_VERMAGIC="6.2.15-215.fc36.armv7hl SMP preempt mod_unload ARMv7 p2v8"
KERNEL_RELEASE="$(make -s -C "$SRC" ARCH=arm kernelrelease)"
REPORT="$ROOT/diretta-h3-v2-compatibility-report.txt"
WORK="$ROOT/.work/diretta-v2"
mkdir -p "$WORK"
: > "$REPORT"

fail() {
  echo "::error::$*" | tee -a "$REPORT" >&2
  exit 1
}

[[ "$KERNEL_RELEASE" == "6.2.15-215.fc36.armv7hl" ]] || fail "Unexpected kernelrelease: $KERNEL_RELEASE"

SAMPLE_KO="$(find "$SRC" -type f -name '*.ko' -print -quit)"
[[ -n "$SAMPLE_KO" ]] || fail "No built kernel module found."
BUILT_VERMAGIC="$(modinfo -F vermagic "$SAMPLE_KO" | xargs)"
[[ "$BUILT_VERMAGIC" == "$EXPECTED_VERMAGIC" ]] || \
  fail "Built module vermagic mismatch: $BUILT_VERMAGIC"

MODULE_DIR="$PKG/lib/modules/$KERNEL_RELEASE/extra/diretta"
mkdir -p "$MODULE_DIR"

{
  echo "Orange Pi PC / Allwinner H3 / Diretta static compatibility report"
  echo "Kernel release: $KERNEL_RELEASE"
  echo "Expected vermagic: $EXPECTED_VERMAGIC"
  echo "Built vermagic: $BUILT_VERMAGIC"
  echo "CONFIG_MODVERSIONS: $(grep -E '^CONFIG_MODVERSIONS=y$' "$SRC/.config" || echo disabled)"
  echo
} | tee -a "$REPORT"

for name in alsa_bridge.ko diretta_direct.ko; do
  source_module="$ROOT/modules/diretta/$name"
  packaged_module="$MODULE_DIR/$name"
  [[ -s "$source_module" ]] || fail "Original Diretta module missing: $name"
  [[ -s "$packaged_module" ]] || fail "Packaged Diretta module missing: $name"

  source_hash="$(sha256sum "$source_module" | awk '{print $1}')"
  packaged_hash="$(sha256sum "$packaged_module" | awk '{print $1}')"
  [[ "$source_hash" == "$packaged_hash" ]] || fail "$name changed during packaging"

  vermagic="$(modinfo -F vermagic "$source_module" | xargs)"
  [[ "$vermagic" == "$EXPECTED_VERMAGIC" ]] || fail "$name original vermagic mismatch: $vermagic"

  readelf -h "$source_module" > "$WORK/$name.elf-header"
  grep -q 'Class:.*ELF32' "$WORK/$name.elf-header" || fail "$name is not ELF32"
  grep -q 'Machine:.*ARM' "$WORK/$name.elf-header" || fail "$name is not an ARM module"

  {
    echo "[$name]"
    echo "SHA256: $source_hash"
    echo "vermagic: $vermagic"
    echo "depends: $(modinfo -F depends "$source_module" | xargs)"
    echo
  } | tee -a "$REPORT"
done

# Module.symvers format: CRC, symbol, provider, export type, namespace.
# These three expected exports are checked explicitly, but remain advisory:
# a missing export is reported rather than aborting compilation/packaging.
{
  echo "[Required kernel exports: CRC 0x00000000 / EXPORT_SYMBOL]"
} >> "$REPORT"

for sym in __check_object_size fortify_panic page_address; do
  if awk -v s="$sym" \
    '$2 == s && $1 == "0x00000000" && $4 == "EXPORT_SYMBOL" {found=1} END {exit !found}' \
    "$SRC/Module.symvers"; then
    awk -v s="$sym" '$2 == s {print}' "$SRC/Module.symvers" >> "$REPORT"
    echo "OK: $sym"
  else
    echo "::warning::Required export absent or CRC/type differs: $sym"
    echo "WARNING: $sym absent or CRC/type differs" >> "$REPORT"
  fi
done

KERNEL_EXPORTS="$WORK/kernel-exports.txt"
PEER_EXPORTS="$WORK/peer-exports.txt"
ALL_EXPORTS="$WORK/all-exports.txt"
awk 'NF >= 2 {print $2}' "$SRC/Module.symvers" | LC_ALL=C sort -u > "$KERNEL_EXPORTS"
: > "$PEER_EXPORTS"

# Collect symbols exported by either supplied module so that cross-module
# references are not incorrectly reported as missing kernel exports.
for module in "$ROOT/modules/diretta/alsa_bridge.ko" "$ROOT/modules/diretta/diretta_direct.ko"; do
  arm-linux-gnueabihf-nm -g --defined-only "$module" 2>/dev/null \
    | awk 'NF && $NF ~ /^__ksymtab(_gpl)?_/ {
        name=$NF
        sub(/^__ksymtab(_gpl)?_/, "", name)
        print name
      }' >> "$PEER_EXPORTS"
done
LC_ALL=C sort -u -o "$PEER_EXPORTS" "$PEER_EXPORTS"
cat "$KERNEL_EXPORTS" "$PEER_EXPORTS" | LC_ALL=C sort -u > "$ALL_EXPORTS"

MISSING_TOTAL=0
for module in "$ROOT/modules/diretta/alsa_bridge.ko" "$ROOT/modules/diretta/diretta_direct.ko"; do
  name="$(basename "$module")"
  imports="$WORK/$name.imports"
  missing="$WORK/$name.missing"
  arm-linux-gnueabihf-nm -u "$module" 2>/dev/null \
    | awk '$1 == "U" {print $2}' | LC_ALL=C sort -u > "$imports"
  comm -23 "$imports" "$ALL_EXPORTS" > "$missing"
  count="$(wc -l < "$missing" | tr -d ' ')"
  MISSING_TOTAL=$((MISSING_TOTAL + count))
  {
    echo "[$name imported-symbol audit]"
    echo "Undefined imports: $(wc -l < "$imports" | tr -d ' ')"
    echo "Absent from kernel and peer-module exports: $count"
    if [[ "$count" -gt 0 ]]; then
      sed 's/^/WARNING: unresolved import: /' "$missing"
    fi
    echo
  } >> "$REPORT"
done

{
  echo "Total unresolved imports: $MISSING_TOTAL"
  echo
  echo "Audit policy:"
  echo "- Exact kernelrelease and vermagic are hard gates."
  echo "- Original module hashes and ARM ELF32 identity are hard gates."
  echo "- MODVERSIONS remains disabled; symbol CRC/type coverage is reported, not used as a build gate."
  echo "- Missing kernel exports/imports and optional hardware config differences are advisory."
  echo "- Static checks cannot prove complete binary ABI or runtime compatibility."
  echo "- Final acceptance requires loading both modules on Orange Pi PC and testing Diretta."
} >> "$REPORT"

# Verify the final boot triplet and rebuilt initramfs module release.
[[ -s "$PKG/boot/zImage" ]] || fail "Packaged zImage is missing"
[[ -s "$PKG/boot/uInitrd" ]] || fail "Packaged uInitrd is missing"
[[ -s "$PKG/boot/dtb/allwinner/sun8i-h3-orangepi-pc.dtb" ]] || fail "Packaged original DTB is missing"
command -v dumpimage >/dev/null || fail "dumpimage is unavailable"
dumpimage -l "$PKG/boot/uInitrd" > "$WORK/uinitrd-header.txt"
grep -q 'Image Type:.*RAMDisk Image' "$WORK/uinitrd-header.txt" || fail "uInitrd is not a U-Boot RAMDisk image"
grep -q 'Architecture:.*ARM' "$WORK/uinitrd-header.txt" || fail "uInitrd architecture is not ARM"
dumpimage -p 0 -o "$WORK/uinitrd-payload.gz" "$PKG/boot/uInitrd"
gzip -t "$WORK/uinitrd-payload.gz" || fail "uInitrd gzip payload is corrupt"
gzip -dc "$WORK/uinitrd-payload.gz" | cpio -it --quiet > "$WORK/uinitrd-files.txt"
grep -Eq '^(\\./)?init || fail "uInitrd /init is missing"
grep -q "^usr/lib/modules/$KERNEL_RELEASE/" "$WORK/uinitrd-files.txt" || fail "uInitrd module directory does not match $KERNEL_RELEASE"
{
  echo "[Boot image audit]"
  echo "zImage bytes: $(stat -c '%s' "$PKG/boot/zImage")"
  echo "uInitrd bytes: $(stat -c '%s' "$PKG/boot/uInitrd")"
  echo "DTB SHA256: $(sha256sum "$PKG/boot/dtb/allwinner/sun8i-h3-orangepi-pc.dtb" | awk '{print $1}')"
  echo "uInitrd header: valid ARM U-Boot RAMDisk"
  echo "uInitrd module release: $KERNEL_RELEASE"
  echo
} | tee -a "$REPORT"

if [[ "$MISSING_TOTAL" -gt 0 ]]; then
  echo "::warning::Some Diretta imports are unresolved in static audit; continuing to package."
fi

cat "$REPORT"
 "$WORK/uinitrd-files.txt" || fail "uInitrd /init is missing"
grep -q "^usr/lib/modules/$KERNEL_RELEASE/" "$WORK/uinitrd-files.txt" || fail "uInitrd module directory does not match $KERNEL_RELEASE"
{
  echo "[Boot image audit]"
  echo "zImage bytes: $(stat -c '%s' "$PKG/boot/zImage")"
  echo "uInitrd bytes: $(stat -c '%s' "$PKG/boot/uInitrd")"
  echo "DTB SHA256: $(sha256sum "$PKG/boot/dtb/allwinner/sun8i-h3-orangepi-pc.dtb" | awk '{print $1}')"
  echo "uInitrd header: valid ARM U-Boot RAMDisk"
  echo "uInitrd module release: $KERNEL_RELEASE"
  echo
} | tee -a "$REPORT"

if [[ "$MISSING_TOTAL" -gt 0 ]]; then
  echo "::warning::Some Diretta imports are unresolved in static audit; continuing to package."
fi

cat "$REPORT"
