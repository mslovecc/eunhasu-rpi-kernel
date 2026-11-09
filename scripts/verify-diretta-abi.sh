#!/usr/bin/env bash
set -Eeuo pipefail

SRC="${1:?Usage: verify-diretta-abi.sh <kernel-source-dir> <package-root>}"
PKG="${2:?Usage: verify-diretta-abi.sh <kernel-source-dir> <package-root>}"
EXPECTED_VERMAGIC="${EXPECTED_VERMAGIC:-6.2.15-215.fc36.armv7hl SMP preempt mod_unload ARMv7 p2v8}"
VERIFY_SYMBOLS="${VERIFY_DIRETTA_SYMBOLS:-true}"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
REPORT="$ROOT/diretta-h3-compatibility-report.txt"
mkdir -p "$(dirname "$REPORT")"
: > "$REPORT"

fail() {
  echo "::error::$*" | tee -a "$REPORT" >&2
  exit 1
}

{
  echo "Orange Pi PC / Allwinner H3 Diretta binary-module compatibility report"
  echo "Expected vermagic: $EXPECTED_VERMAGIC"
  echo "Kernel release: $(make -s -C "$SRC" ARCH=arm kernelrelease)"
  echo "CONFIG_MODVERSIONS: $(grep -E '^CONFIG_MODVERSIONS=y$' "$SRC/.config" || echo disabled)"
  echo "Verification date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
} | tee -a "$REPORT"

MODULE_DIR="$PKG/lib/modules/$(make -s -C "$SRC" ARCH=arm kernelrelease)/extra/diretta"
mkdir -p "$MODULE_DIR"

for name in alsa_bridge.ko diretta_direct.ko; do
  source_module="$ROOT/modules/diretta/$name"
  target_module="$MODULE_DIR/$name"

  [[ -s "$source_module" ]] || fail "Missing original module: $source_module"
  [[ -s "$target_module" ]] || fail "Unmodified original module not found in package: $target_module"

  source_hash="$(sha256sum "$source_module" | awk '{print $1}')"
  target_hash="$(sha256sum "$target_module" | awk '{print $1}')"
  [[ "$source_hash" == "$target_hash" ]] || fail "$name was changed during packaging"

  vermagic="$(modinfo -F vermagic "$source_module" | xargs)"
  [[ "$vermagic" == "$EXPECTED_VERMAGIC" ]] || fail "$name vermagic mismatch: $vermagic"

  readelf -h "$source_module" | grep -q 'Class:.*ELF32' || fail "$name is not ELF32"
  readelf -h "$source_module" | grep -q 'Machine:.*ARM' || fail "$name is not an ARM ELF module"

  {
    echo "[$name]"
    echo "SHA256: $source_hash"
    echo "vermagic: $vermagic"
    echo "depends: $(modinfo -F depends "$source_module" | xargs)"
    echo
  } | tee -a "$REPORT"
done

if [[ "$(modinfo -F depends "$ROOT/modules/diretta/alsa_bridge.ko" | tr -d '[:space:]')" != "snd,snd-pcm" ]]; then
  fail "alsa_bridge.ko dependency metadata differs from the recorded v4 baseline (expected snd,snd-pcm)"
fi

# The original v4 configuration and the Fedora ARMv7 config both disable
# CONFIG_MODVERSIONS. In this mode Module.symvers can prove export-name
# availability, but cannot prove symbol CRC/type-layout ABI compatibility.
if grep -qx 'CONFIG_MODVERSIONS=y' "$SRC/.config"; then
  fail "CONFIG_MODVERSIONS unexpectedly enabled; this checker does not claim CRC compatibility."
fi

EXPORTS="$ROOT/.work/h3-exported-symbols.txt"
mkdir -p "$ROOT/.work"
awk 'NF >= 2 {print $2}' "$SRC/Module.symvers" | sort -u > "$EXPORTS"

missing_total=0
for module in "$ROOT/modules/diretta/alsa_bridge.ko" "$ROOT/modules/diretta/diretta_direct.ko"; do
  name="$(basename "$module")"
  imports="$ROOT/.work/$name.imports"
  missing="$ROOT/.work/$name.missing"

  arm-linux-gnueabihf-nm -u "$module" 2>/dev/null \
    | awk '$1 == "U" {print $2}' \
    | sort -u > "$imports"

  comm -23 "$imports" "$EXPORTS" > "$missing"
  count="$(wc -l < "$missing" | tr -d ' ')"
  missing_total=$((missing_total + count))

  {
    echo "[$name imported-symbol check]"
    echo "Imported symbols: $(wc -l < "$imports" | tr -d ' ')"
    echo "Missing from Module.symvers: $count"
    if [[ "$count" -gt 0 ]]; then
      cat "$missing"
    fi
    echo
  } | tee -a "$REPORT"
done

if [[ "$VERIFY_SYMBOLS" == "true" && "$missing_total" -gt 0 ]]; then
  fail "Diretta imports missing from the new kernel Module.symvers ($missing_total)."
fi

cat >> "$REPORT" <<'EOF'
LIMITATION:
- vermagic, ELF machine/class, dependency metadata, and exported symbol-name
  checks are static compatibility gates only.
- CONFIG_MODVERSIONS is disabled, so this build has no symbol CRC comparison.
- These checks do not prove structure layout, calling convention, locking,
  runtime behavior, or complete binary ABI compatibility.
- Do not use insmod -f or modprobe --force to bypass a load failure.
- Final acceptance requires loading both original modules on the Orange Pi PC
  and exercising Diretta audio/network operation.
EOF

echo "Static Diretta checks passed. Runtime compatibility remains unproven."
