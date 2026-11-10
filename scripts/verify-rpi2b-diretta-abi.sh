#!/usr/bin/env bash
set -Eeuo pipefail

SRC="${1:?Usage: verify-rpi2b-diretta-abi.sh <kernel-source-dir> <report-path>}"
REPORT="${2:?Usage: verify-rpi2b-diretta-abi.sh <kernel-source-dir> <report-path>}"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
ALSA="$ROOT/modules/diretta/alsa_bridge.ko"
DIRECT="$ROOT/modules/diretta/diretta_direct.ko"
EXPECTED_RELEASE="6.2.15-215.fc36.armv7hl"
EXPECTED_VERMAGIC="$EXPECTED_RELEASE SMP preempt mod_unload ARMv7 p2v8"
CROSS_NM="${CROSS_COMPILE:-arm-linux-gnueabihf-}nm"

fail() { echo "::error::$*" | tee -a "$REPORT" >&2; exit 1; }
mkdir -p "$(dirname "$REPORT")"
: > "$REPORT"
exec > >(tee -a "$REPORT") 2>&1

echo "Strict Raspberry Pi 2B / Diretta ABI audit"
echo "Kernel source: $SRC"
echo "Expected release: $EXPECTED_RELEASE"
echo "Expected vermagic: $EXPECTED_VERMAGIC"

[[ -s "$SRC/.config" && -s "$SRC/Module.symvers" && -s "$SRC/vmlinux" ]] || fail "Missing current-build .config, Module.symvers or vmlinux"
[[ -s "$ALSA" && -s "$DIRECT" ]] || fail "Original Diretta module missing"
[[ "$(make -s -C "$SRC" ARCH=arm kernelrelease)" == "$EXPECTED_RELEASE" ]] || fail "kernelrelease mismatch"

for cfg in CONFIG_ARM CONFIG_ARCH_MULTI_V7 CONFIG_CPU_V7 CONFIG_NEON CONFIG_SMP CONFIG_PREEMPT CONFIG_MODULES CONFIG_MODULE_UNLOAD CONFIG_HIGHMEM CONFIG_HARDENED_USERCOPY CONFIG_FORTIFY_SOURCE; do
  grep -qx "$cfg=y" "$SRC/.config" || fail "$cfg must be enabled"
done
for cfg in CONFIG_MODVERSIONS CONFIG_MODULE_SIG; do
  grep -qx "# $cfg is not set" "$SRC/.config" || fail "$cfg must be disabled"
done
if grep -qx 'CONFIG_MODULE_SIG_FORCE=y' "$SRC/.config"; then
  fail "Forced module signatures must not be enabled"
fi
grep -qx 'CONFIG_LOCALVERSION="-215.fc36.armv7hl"' "$SRC/.config" || fail "LOCALVERSION mismatch"
grep -qx '# CONFIG_LOCALVERSION_AUTO is not set' "$SRC/.config" || fail "LOCALVERSION_AUTO must be disabled"

for mod in "$ALSA" "$DIRECT"; do
  vm="$(modinfo -F vermagic "$mod" | xargs)"
  [[ "$vm" == "$EXPECTED_VERMAGIC" ]] || fail "$(basename "$mod") vermagic mismatch: $vm"
  readelf -h "$mod" | grep -q 'Class:.*ELF32' || fail "$(basename "$mod") is not ELF32"
  readelf -h "$mod" | grep -q 'Machine:.*ARM' || fail "$(basename "$mod") is not ARM ELF"
done
[[ "$(sha256sum "$ALSA" | awk '{print $1}')" == "2fdb6d8dd5179988e13be85442cabebe3816adac4c01e0094a87aa34b1aea2db" ]] || fail "alsa_bridge.ko source hash changed"
[[ "$(sha256sum "$DIRECT" | awk '{print $1}')" == "b0fc07fbbbe8f5bd2f007927ecc98d6d7f23753973226f8fc489ea9374ea4ed0" ]] || fail "diretta_direct.ko source hash changed"

echo
echo "[Required kernel exports: exact CRC and export class]"
for sym in __check_object_size fortify_panic page_address; do
  row="$(awk -v s="$sym" '$2==s {print}' "$SRC/Module.symvers")"
  [[ -n "$row" ]] || fail "$sym absent from this build's Module.symvers"
  [[ "$(printf '%s\n' "$row" | wc -l)" -eq 1 ]] || fail "$sym has duplicate Module.symvers entries"
  printf '%s\n' "$row" | awk '$1=="0x00000000" && $4=="EXPORT_SYMBOL" {ok=1} END{exit !ok}' || fail "$sym CRC/export type mismatch: $row"
  echo "PASS: $row"
done

echo
echo "[All undefined imports and peer-module exports]"
mkdir -p "$ROOT/.work/diretta-strict"
for mod in "$ALSA" "$DIRECT"; do
  name="$(basename "$mod")"
  "$CROSS_NM" -u "$mod" 2>/dev/null | awk '$1=="U"{print $2}' | sort -u > "$ROOT/.work/diretta-strict/$name.imports"
  "$CROSS_NM" -a "$mod" 2>/dev/null | awk '
    {
      s=$NF
      if (s ~ /^__ksymtab_/) {sub(/^__ksymtab_/,"",s); print s}
      else if (s ~ /^___ksymtab[+]/) {sub(/^___ksymtab[+]/,"",s); print s}
    }' | sort -u > "$ROOT/.work/diretta-strict/$name.exports"
done
cat "$ROOT/.work/diretta-strict/"*.exports | sort -u > "$ROOT/.work/diretta-strict/peer.exports"
awk 'NF>=2 {print $2}' "$SRC/Module.symvers" | sort -u > "$ROOT/.work/diretta-strict/kernel.exports"
for mod in "$ALSA" "$DIRECT"; do
  name="$(basename "$mod")"
  peer="diretta_direct.ko"
  [[ "$name" == "diretta_direct.ko" ]] && peer="alsa_bridge.ko"
  cat "$ROOT/.work/diretta-strict/kernel.exports" "$ROOT/.work/diretta-strict/$peer.exports" | sort -u > "$ROOT/.work/diretta-strict/$name.allowed"
  comm -23 "$ROOT/.work/diretta-strict/$name.imports" "$ROOT/.work/diretta-strict/$name.allowed" > "$ROOT/.work/diretta-strict/$name.missing"
  if [[ -s "$ROOT/.work/diretta-strict/$name.missing" ]]; then
    cat "$ROOT/.work/diretta-strict/$name.missing"
    fail "$name has unresolved imports against this kernel and the peer module"
  fi
  echo "PASS: $name imports resolved ($(wc -l < "$ROOT/.work/diretta-strict/$name.imports") symbols)"
done

echo
echo "[ARM ELF attributes]"
SAMPLE_KO="$(find "$SRC" -type f -name '*.ko' -print -quit)"
[[ -n "$SAMPLE_KO" ]] || fail "No kernel-built reference module exists for ARM attribute comparison"
readelf -A "$ALSA" > "$ROOT/.work/diretta-strict/alsa.attributes"
readelf -A "$DIRECT" > "$ROOT/.work/diretta-strict/direct.attributes"
readelf -A "$SAMPLE_KO" > "$ROOT/.work/diretta-strict/kernel-module.attributes"
for f in "$ROOT/.work/diretta-strict/"*.attributes; do
  grep -q 'Tag_CPU_arch' "$f" || fail "ARM attributes absent: $f"
done
diff -u "$ROOT/.work/diretta-strict/kernel-module.attributes" "$ROOT/.work/diretta-strict/alsa.attributes" || fail "alsa_bridge ARM attributes differ from this kernel build"
diff -u "$ROOT/.work/diretta-strict/kernel-module.attributes" "$ROOT/.work/diretta-strict/direct.attributes" || fail "diretta_direct ARM attributes differ from this kernel build"
echo "PASS: both Diretta modules match the build's ARM ELF attributes"

echo
echo "[struct module size/layout sanity gate]"
command -v pahole >/dev/null || fail "pahole is required for struct module inspection"
pahole -C module "$SRC/vmlinux" > "$ROOT/.work/diretta-strict/struct-module.txt" || fail "Cannot extract struct module from this build's vmlinux DWARF"
STRUCT_SIZE="$(sed -nE 's@.*size:[[:space:]]*([0-9]+),[[:space:]]*cachelines.*@\1@p' "$ROOT/.work/diretta-strict/struct-module.txt" | tail -n1)"
[[ "$STRUCT_SIZE" =~ ^[0-9]+$ ]] || fail "Could not parse struct module size from pahole output"
for mod in "$ALSA" "$DIRECT"; do
  SECTION_HEX="$(readelf -SW "$mod" | awk '{for(i=1;i<=NF;i++) if($i==".gnu.linkonce.this_module"){print $(i+4); exit}}')"
  [[ "$SECTION_HEX" =~ ^[0-9a-fA-F]+$ ]] || fail "$(basename "$mod"): missing .gnu.linkonce.this_module section"
  SECTION_SIZE=$((16#$SECTION_HEX))
  [[ "$SECTION_SIZE" -eq "$STRUCT_SIZE" ]] || fail "$(basename "$mod"): this_module section=$SECTION_SIZE, kernel struct module=$STRUCT_SIZE"
  echo "PASS: $(basename "$mod") struct module size $SECTION_SIZE"
done

echo
echo "[Signature policy]"
[[ "$(modinfo -F signer "$ALSA" | xargs)" == "" ]] || echo "NOTE: alsa_bridge has a signer; kernel does not enforce signatures"
[[ "$(modinfo -F signer "$DIRECT" | xargs)" == "" ]] || echo "NOTE: diretta_direct has a signer; kernel does not enforce signatures"
grep -qx '# CONFIG_MODULE_SIG is not set' "$SRC/.config" || fail "Module signing unexpectedly enabled"
if grep -qx 'CONFIG_MODULE_SIG_FORCE=y' "$SRC/.config"; then
  fail "Forced module signatures unexpectedly enabled"
fi

echo
echo "STATIC ABI GATES PASSED."
echo "This does NOT prove runtime loading, device-tree, initramfs or audio/network operation."
echo "Do not use insmod -f or modprobe --force."
