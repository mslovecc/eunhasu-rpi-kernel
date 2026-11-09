#!/usr/bin/env bash
set -Eeuo pipefail

SRC="${1:?Usage: prepare-h3-config.sh <kernel-source-dir> <expected-release>}"
EXPECTED_RELEASE="${2:?Usage: prepare-h3-config.sh <kernel-source-dir> <expected-release>}"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
SUPPORT_DIR="$ROOT/sources/kernel-srpm"
H3_FRAGMENT="$ROOT/config/h3-orangepi-pc.fragment"
DIRETTA_FRAGMENT="$ROOT/config/h3-diretta.fragment"

for file in \
  "$SRC/Makefile" \
  "$SUPPORT_DIR/kernel-armv7hl-fedora.config" \
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

SOURCE_VERSION="$(make -s kernelversion)"
[[ "$SOURCE_VERSION" == "6.2.15" ]] || {
  echo "::error::Expected Linux 6.2.15 source, got $SOURCE_VERSION"
  exit 1
}

# Start from the Fedora ARMv7 config used for the original Diretta modules.
# It already enables ARCH_SUNXI and MACH_SUN8I, preserving much more of the
# original kernel's generic configuration than sunxi_defconfig would.
cp "$SUPPORT_DIR/kernel-armv7hl-fedora.config" .config

bash scripts/kconfig/merge_config.sh -m -r .config \
  "$H3_FRAGMENT" \
  "$DIRETTA_FRAGMENT"

# Explicitly enforce the release and the non-forced signature policy.
scripts/config --file .config \
  --set-str LOCALVERSION "" \
  --disable LOCALVERSION_AUTO \
  --disable MODVERSIONS \
  --disable MODULE_SIG_FORCE \
  --enable MODULES \
  --enable MODULE_UNLOAD \
  --enable PREEMPT

make olddefconfig
make syncconfig

printf '%s\n' "-215.fc36.armv7hl" > localversion

ACTUAL_RELEASE="$(make -s kernelrelease)"
echo "Expected kernel release: $EXPECTED_RELEASE"
echo "Actual kernel release:   $ACTUAL_RELEASE"

[[ "$ACTUAL_RELEASE" == "$EXPECTED_RELEASE" ]] || {
  echo "::error::Kernel release mismatch; refusing to build binary Diretta modules against a different release."
  exit 1
}

cp .config "$ROOT/output-orangepi-pc.config"
cp localversion "$ROOT/output-orangepi-pc.localversion"

echo "H3 configuration prepared."
