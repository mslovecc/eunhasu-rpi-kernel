#!/usr/bin/env bash
set -Eeuo pipefail

SRC="${1:?Usage: prepare-h3-config.sh <kernel-source-dir> <expected-release>}"
EXPECTED_RELEASE="${2:?Usage: prepare-h3-config.sh <kernel-source-dir> <expected-release>}"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
H3_FRAGMENT="$ROOT/config/h3-orangepi-pc.fragment"
DIRETTA_FRAGMENT="$ROOT/config/h3-diretta.fragment"

for file in \
  "$SRC/Makefile" \
  "$SRC/arch/arm/configs/sunxi_defconfig" \
  "$H3_FRAGMENT" \
  "$DIRETTA_FRAGMENT"; do
  test -s "$file" || {
    echo "::error::Required configuration input missing: $file"
    exit 1
  }
done

cd "$SRC"
export ARCH=arm
export CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabihf-}"

SOURCE_VERSION="$(make -s ARCH=arm kernelversion)"
[[ "$SOURCE_VERSION" == "6.2.15" ]] || {
  echo "::error::Expected Linux 6.2.15 source, got $SOURCE_VERSION"
  exit 1
}

# Start from the upstream Allwinner/Sunxi baseline shipped with this exact
# Linux 6.2.15 source tree. This intentionally replaces the former Fedora
# generic ARMv7 configuration baseline.
make ARCH=arm sunxi_defconfig

# Merge board-specific H3 and prebuilt-Diretta requirements.
bash scripts/kconfig/merge_config.sh -m -r .config \
  "$H3_FRAGMENT" \
  "$DIRETTA_FRAGMENT"

# Preserve the supplied binary module's required kernel release and vermagic
# characteristics. MODVERSIONS stays disabled, matching the original setup.
scripts/config --file .config \
  --set-str LOCALVERSION "" \
  --disable LOCALVERSION_AUTO \
  --disable MODVERSIONS \
  --disable MODULE_SIG_FORCE \
  --enable MODULES \
  --enable MODULE_UNLOAD \
  --enable PREEMPT

make ARCH=arm olddefconfig
make ARCH=arm syncconfig

printf '%s\n' "-215.fc36.armv7hl" > localversion

ACTUAL_RELEASE="$(make -s ARCH=arm kernelrelease)"
echo "Configuration baseline: arch/arm/configs/sunxi_defconfig"
echo "Expected kernel release: $EXPECTED_RELEASE"
echo "Actual kernel release:   $ACTUAL_RELEASE"

[[ "$ACTUAL_RELEASE" == "$EXPECTED_RELEASE" ]] || {
  echo "::error::Kernel release mismatch; refusing to build binary Diretta modules against a different release."
  exit 1
}

cp .config "$ROOT/output-orangepi-pc.config"
cp localversion "$ROOT/output-orangepi-pc.localversion"

echo "H3 sunxi_defconfig + Orange Pi PC + Diretta configuration prepared."
