#!/usr/bin/env bash
set -Eeuo pipefail

SRC="${1:?Usage: verify-h3-config.sh <kernel-source-dir> <expected-release>}"
EXPECTED_RELEASE="${2:?Usage: verify-h3-config.sh <kernel-source-dir> <expected-release>}"

cd "$SRC"
test -s .config
test -s arch/arm/boot/dts/sun8i-h3-orangepi-pc.dts
test -s arch/arm/boot/dts/sun8i-h3.dtsi

required=(
  CONFIG_ARCH_SUNXI=y
  CONFIG_MACH_SUN8I=y
  CONFIG_CPU_V7=y
  CONFIG_AEABI=y
  CONFIG_SMP=y
  CONFIG_PREEMPT=y
  CONFIG_MODULES=y
  CONFIG_MODULE_UNLOAD=y
  CONFIG_MMC=y
  CONFIG_MMC_BLOCK=y
  CONFIG_MMC_SUNXI=y
  CONFIG_EXT4_FS=y
  CONFIG_DEVTMPFS=y
  CONFIG_DEVTMPFS_MOUNT=y
  CONFIG_SERIAL_8250=y
  CONFIG_SERIAL_8250_CONSOLE=y
  CONFIG_SERIAL_8250_DW=y
  CONFIG_DWMAC_SUN8I=y
  CONFIG_PHYLIB=y
  CONFIG_USB=y
  CONFIG_USB_EHCI_HCD=y
  CONFIG_USB_OHCI_HCD=y
  CONFIG_SND=m
  CONFIG_SND_PCM=m
  CONFIG_SND_TIMER=m
  CONFIG_HARDENED_USERCOPY=y
  CONFIG_FORTIFY_SOURCE=y
  CONFIG_HIGHMEM=y
  CONFIG_NEON=y
)

for item in "${required[@]}"; do
  if ! grep -qx "$item" .config; then
    echo "::error::Required H3/Diretta config missing after olddefconfig: $item"
    exit 1
  fi
  echo "OK $item"
done

if grep -qx 'CONFIG_MODVERSIONS=y' .config; then
  echo "::error::CONFIG_MODVERSIONS must remain disabled for this first binary-module compatibility test."
  exit 1
fi

if grep -qx 'CONFIG_MODULE_SIG_FORCE=y' .config; then
  echo "::error::Forced module signatures would reject the supplied unsigned Diretta modules."
  exit 1
fi

ACTUAL_RELEASE="$(make -s ARCH=arm kernelrelease)"
[[ "$ACTUAL_RELEASE" == "$EXPECTED_RELEASE" ]] || {
  echo "::error::kernelrelease mismatch: $ACTUAL_RELEASE"
  exit 1
}

echo
echo "===== Orange Pi PC device-tree source ====="
grep -nE 'compatible|model' arch/arm/boot/dts/sun8i-h3-orangepi-pc.dts | head -n 20

echo
echo "H3 config validation passed: $ACTUAL_RELEASE"
