#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: prepare-h3-v2-config.sh <kernel-source-dir> <expected-kernelrelease>" >&2
  exit 2
fi

SRC="$1"
EXPECTED_RELEASE="$2"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
ARMBIAN_CONFIG="$ROOT/config/config-6.18.35-current-sunxi"

test -s "$SRC/Makefile"
test -s "$ARMBIAN_CONFIG"
test -s "$SRC/scripts/config"
test -s "$SRC/scripts/kconfig/merge_config.sh"

SOURCE_VERSION="$(make -s -C "$SRC" ARCH=arm kernelversion)"
[[ "$SOURCE_VERSION" == "6.2.15" ]] || {
  echo "::error::Expected Linux 6.2.15 source, got $SOURCE_VERSION"
  exit 1
}

cd "$SRC"
mkdir -p "$ROOT/.work"
cp "$ARMBIAN_CONFIG" .config
cp .config "$ROOT/output-orangepi-pc-h3-v2-base.config"

cat > "$ROOT/.work/h3-v2-diretta.fragment" <<'EOF'
CONFIG_ARCH_SUNXI=y
CONFIG_MACH_SUN8I=y
CONFIG_CPU_V7=y
CONFIG_AEABI=y
CONFIG_ARM_PATCH_PHYS_VIRT=y
CONFIG_SMP=y
CONFIG_PREEMPT=y
# CONFIG_PREEMPT_NONE is not set
# CONFIG_PREEMPT_VOLUNTARY is not set
CONFIG_MODULES=y
CONFIG_MODULE_UNLOAD=y
# CONFIG_MODVERSIONS is not set
# CONFIG_THUMB2_KERNEL is not set
# CONFIG_MODULE_SIG is not set
# CONFIG_MODULE_SIG_FORCE is not set
CONFIG_SOUND=y
CONFIG_SND=m
CONFIG_SND_PCM=m
CONFIG_SND_TIMER=m
EOF

bash scripts/kconfig/merge_config.sh -m .config \
  "$ROOT/.work/h3-v2-diretta.fragment"

bash scripts/config --file .config \
  --set-str LOCALVERSION "" \
  --disable LOCALVERSION_AUTO \
  --enable ARCH_SUNXI \
  --enable MACH_SUN8I \
  --enable CPU_V7 \
  --enable AEABI \
  --enable ARM_PATCH_PHYS_VIRT \
  --enable SMP \
  --enable PREEMPT \
  --disable PREEMPT_NONE \
  --disable PREEMPT_VOLUNTARY \
  --enable MODULES \
  --enable MODULE_UNLOAD \
  --disable MODVERSIONS \
  --disable THUMB2_KERNEL \
  --disable MODULE_SIG \
  --disable MODULE_SIG_FORCE \
  --enable SOUND \
  --module SND \
  --module SND_PCM \
  --module SND_TIMER

make ARCH=arm olddefconfig
make ARCH=arm syncconfig
printf '%s\n' '-215.fc36.armv7hl' > localversion

ACTUAL_RELEASE="$(make -s ARCH=arm kernelrelease)"
echo "Expected kernelrelease: $EXPECTED_RELEASE"
echo "Actual kernelrelease:   $ACTUAL_RELEASE"
[[ "$ACTUAL_RELEASE" == "$EXPECTED_RELEASE" ]] || {
  echo "::error::Kernel release mismatch."
  exit 1
}

for item in \
  CONFIG_ARCH_SUNXI=y \
  CONFIG_MACH_SUN8I=y \
  CONFIG_CPU_V7=y \
  CONFIG_AEABI=y \
  CONFIG_ARM_PATCH_PHYS_VIRT=y \
  CONFIG_SMP=y \
  CONFIG_PREEMPT=y \
  CONFIG_MODULES=y \
  CONFIG_MODULE_UNLOAD=y \
  CONFIG_SOUND=y \
  CONFIG_SND=m \
  CONFIG_SND_PCM=m; do
  grep -qx "$item" .config || {
    echo "::error::Required setting did not survive Kconfig: $item"
    exit 1
  }
done

for sym in CONFIG_MODVERSIONS CONFIG_THUMB2_KERNEL CONFIG_MODULE_SIG_FORCE; do
  if grep -qx "$sym=y" .config; then
    echo "::error::$sym must not be enabled."
    exit 1
  fi
done

if grep -qx 'CONFIG_MODULE_SIG=y' .config; then
  echo "::warning::Module signing support is enabled, but forced signature verification is disabled."
fi

REPORT="$ROOT/h3-v2-config-report.txt"
{
  echo "Base config: config/config-6.18.35-current-sunxi (Linux 6.18.35)"
  echo "Build source: Linux $SOURCE_VERSION + Fedora SRPM patch"
  echo "Final kernel release: $ACTUAL_RELEASE"
  echo
  echo "[ABI-related final settings]"
  grep -E '^(CONFIG_(ARCH_SUNXI|MACH_SUN8I|CPU_V7|AEABI|ARM_PATCH_PHYS_VIRT|SMP|PREEMPT|MODULES|MODULE_UNLOAD|MODVERSIONS|THUMB2_KERNEL|MODULE_SIG|MODULE_SIG_FORCE|SND|SND_PCM|SND_TIMER))=' .config || true
  echo
  echo "[Advisory H3 hardware settings]"
  for sym in CONFIG_STMMAC_ETH CONFIG_DWMAC_SUN8I CONFIG_MMC CONFIG_MMC_SUNXI \
    CONFIG_USB CONFIG_USB_EHCI_HCD CONFIG_USB_OHCI_HCD CONFIG_EXT4_FS; do
    if grep -qx "$sym=y" .config || grep -qx "$sym=m" .config; then
      echo "available: $sym"
    else
      echo "advisory: $sym absent/disabled in Linux 6.2.15 effective config"
    fi
  done
} | tee "$REPORT"

cp .config "$ROOT/output-orangepi-pc.config"
cp localversion "$ROOT/output-orangepi-pc.localversion"
echo "H3 V2 Armbian-base configuration prepared."
