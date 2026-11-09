#!/usr/bin/env bash
set -Eeuo pipefail

test -n "$SRC"
test -n "$RPI_SRC"
test -n "$GITHUB_WORKSPACE"
test -n "$SUPPORT_DIR"
test -n "$ABI_FRAGMENT"
test -n "$CROSS_COMPILE"
test -n "$KERNEL_RELEASE"

BASE_CONFIG="$GITHUB_WORKSPACE/$SUPPORT_DIR/kernel-armv7hl-fedora.config"
ABI_CONFIG="$GITHUB_WORKSPACE/$ABI_FRAGMENT"
PI_OFFICIAL="$RPI_SRC/arch/arm/configs/bcm2709_defconfig"
PI_MATCHED="$SRC/arch/arm/configs/bcm2835_defconfig"
WORK="$GITHUB_WORKSPACE/.work"
PI_FRAGMENT="$WORK/rpi2-rpi3-intersection.fragment"
PI_REPORT="$WORK/rpi2-rpi3-intersection-report.txt"
HARDWARE_REPORT="$WORK/rpi2-rpi3-hardware-audit.txt"

for f in "$BASE_CONFIG" "$ABI_CONFIG" "$PI_OFFICIAL" "$PI_MATCHED"; do
  test -s "$f" || {
    echo "::error::Required configuration reference is missing: $f"
    exit 1
  }
done

mkdir -p "$WORK"
cd "$SRC"

echo "===== 1. Start from the repository Fedora ARMv7 config ====="
cp "$BASE_CONFIG" .config
rm -f include/config/auto.conf include/generated/autoconf.h
make ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
cp .config "$WORK/fedora-base-resolved.config"

echo "===== 2. Build supported Raspberry Pi config intersection ====="
python3 - "$BASE_CONFIG" "$PI_OFFICIAL" "$PI_MATCHED" .config "$PI_FRAGMENT" "$PI_REPORT" <<'PY'
import re
import sys
from pathlib import Path

base_path, official_path, matched_path, resolved_path, fragment_path, report_path = map(Path, sys.argv[1:])

def parse(path):
    result = {}
    for raw in path.read_text(errors="replace").splitlines():
        line = raw.strip()
        m = re.fullmatch(r"CONFIG_([A-Z0-9_]+)=(.*)", line)
        if m:
            result[m.group(1)] = m.group(2)
            continue
        m = re.fullmatch(r"# CONFIG_([A-Z0-9_]+) is not set", line)
        if m:
            result[m.group(1)] = "n"
    return result

base = parse(base_path)
resolved = parse(resolved_path)
official = parse(official_path)
matched = parse(matched_path)

# These choices describe the Diretta ABI or package format, not Pi hardware.
# They remain controlled by the repository Fedora config and A20 ABI fragment.
protected = {
    "MODVERSIONS",
    "MODULE_COMPRESS", "MODULE_COMPRESS_GZIP", "MODULE_COMPRESS_NONE",
    "MODULE_COMPRESS_XZ", "MODULE_COMPRESS_ZSTD",
    "PREEMPT", "PREEMPT_NONE", "PREEMPT_VOLUNTARY", "PREEMPT_DYNAMIC",
    "PREEMPT_RT", "LOCALVERSION", "LOCALVERSION_AUTO",
}

# Official Pi 2/3 config is primary. The matching 6.2.15 bcm2835_defconfig
# supplies legacy hardware symbols absent from newer Pi defconfigs.
candidates = {}
for source in (matched, official):
    for name, value in source.items():
        if value in ("y", "m") and name not in protected:
            candidates[name] = value

applied = []
not_in_repo = []
not_supported = []
for name, value in sorted(candidates.items()):
    if name not in base:
        not_in_repo.append((name, value))
    elif name not in resolved:
        not_supported.append((name, value))
    else:
        applied.append((name, value))

fragment_path.parent.mkdir(parents=True, exist_ok=True)
fragment_path.write_text("".join("CONFIG_" + name + "=" + value + "\n" for name, value in applied))

rows = [
    "Raspberry Pi 2/3 configuration intersection",
    "Repository base: " + str(base_path),
    "Official reference: " + str(official_path),
    "Version-matched reference: " + str(matched_path),
    "Applied symbols: " + str(len(applied)),
    "Skipped (not present in repository Fedora config): " + str(len(not_in_repo)),
    "Skipped (not recognized by this source/Kconfig): " + str(len(not_supported)),
    "",
    "[APPLIED]",
    *("CONFIG_" + name + "=" + value for name, value in applied),
    "",
    "[SKIPPED: NOT IN REPOSITORY CONFIG]",
    *("CONFIG_" + name + "=" + value for name, value in not_in_repo),
    "",
    "[SKIPPED: NOT SUPPORTED BY THIS SOURCE]",
    *("CONFIG_" + name + "=" + value for name, value in not_supported),
]
report_path.write_text("\n".join(rows) + "\n")
print("\n".join(rows))
PY

if [[ -s "$PI_FRAGMENT" ]]; then
  bash scripts/kconfig/merge_config.sh -m -r .config "$PI_FRAGMENT"
fi

echo "===== 2.1 Ensure SD-card boot drivers are built in (only if in repo config and source) ====="
for sym in MMC_BLOCK MMC_BCM2835; do
  grep -Eq "^CONFIG_$sym=" "$BASE_CONFIG" || {
    echo "::error::Repository Fedora config does not define required Pi SD option CONFIG_$sym."
    exit 1
  }
  grep -Eq "^CONFIG_$sym=|^# CONFIG_$sym is not set" "$WORK/fedora-base-resolved.config" || {
    echo "::error::Linux 6.2.15 source does not support repository option CONFIG_$sym."
    exit 1
  }
  scripts/config --file .config --enable "$sym"
done

echo "===== 3. Apply only the A20 Diretta ABI fragment ====="
bash scripts/kconfig/merge_config.sh -m -r .config "$ABI_CONFIG"

echo "===== 4. Resolve and validate Kconfig ====="
make ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
make ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" syncconfig

python3 - "$PI_FRAGMENT" .config "$PI_REPORT" <<'PY'
import re
import sys
from pathlib import Path

fragment_path, final_path, report_path = map(Path, sys.argv[1:])
selected = {}
for line in fragment_path.read_text().splitlines():
    m = re.fullmatch(r"CONFIG_([A-Z0-9_]+)=(y|m)", line.strip())
    if m:
        selected[m.group(1)] = m.group(2)

final = {}
for line in final_path.read_text().splitlines():
    line = line.strip()
    m = re.fullmatch(r"CONFIG_([A-Z0-9_]+)=(.*)", line)
    if m:
        final[m.group(1)] = m.group(2)
    else:
        m = re.fullmatch(r"# CONFIG_([A-Z0-9_]+) is not set", line)
        if m:
            final[m.group(1)] = "n"

dropped = [(name, value, final.get(name, "<missing>"))
           for name, value in sorted(selected.items())
           if final.get(name, "n") not in ("y", "m")]
with report_path.open("a") as out:
    out.write("\n[NOT RETAINED AFTER olddefconfig - dependency/choice resolution]\n")
    if dropped:
        out.writelines("CONFIG_" + n + "=" + v + " -> " + actual + "\n"
                       for n, v, actual in dropped)
    else:
        out.write("none\n")
print("[Pi reference options not retained by Kconfig]")
if dropped:
    for name, value, actual in dropped:
        print("CONFIG_" + name + "=" + value + " -> " + actual)
else:
    print("none")
PY

require_config() {
  local expected="$1"
  grep -Fqx "$expected" .config || {
    echo "::error::Required setting not retained: $expected"
    return 1
  }
  echo "OK: $expected"
}

for setting in \
  CONFIG_ARCH_BCM2835=y \
  CONFIG_ARCH_MULTI_V7=y \
  CONFIG_AEABI=y \
  CONFIG_SMP=y \
  CONFIG_PREEMPT=y \
  CONFIG_MODULES=y \
  CONFIG_MODULE_UNLOAD=y \
  CONFIG_HARDENED_USERCOPY=y \
  CONFIG_FORTIFY_SOURCE=y \
  CONFIG_HIGHMEM=y \
  CONFIG_NEON=y \
  CONFIG_MMC=y \
  CONFIG_MMC_BLOCK=y \
  CONFIG_MMC_BCM2835=y; do
  require_config "$setting"
done

grep -qx '# CONFIG_MODVERSIONS is not set' .config || {
  echo "::error::CONFIG_MODVERSIONS must remain disabled for the supplied Diretta vermagic."
  exit 1
}

for sym in PREEMPT_RT THUMB2_KERNEL; do
  if grep -qx "CONFIG_$sym=y" .config; then
    echo "::error::CONFIG_$sym=y is incompatible with the supplied Diretta vermagic."
    exit 1
  fi
done

echo "===== 5. Exclude hardware buses and drivers absent from Raspberry Pi 2/3 ====="
# Pi 2/3 has no PCI/PCIe, SATA, or NVMe host interface. Keep shared SCSI/USB
# storage, DRM core, VC4 and simpledrm; remove only non-target hardware.
python3 - .config <<'PY' > "$WORK/rpi2-rpi3-hardware-disable.list"
import re, sys
from pathlib import Path
values = {}
for raw in Path(sys.argv[1]).read_text().splitlines():
    line = raw.strip()
    m = re.fullmatch(r"CONFIG_([A-Z0-9_]+)=(.*)", line)
    if m: values[m.group(1)] = m.group(2)
    else:
        m = re.fullmatch(r"# CONFIG_([A-Z0-9_]+) is not set", line)
        if m: values[m.group(1)] = "n"
gpu = {
    "DRM_AMDGPU", "DRM_NOUVEAU", "DRM_RADEON",
    "DRM_AST", "DRM_BOCHS", "DRM_CIRRUS_QEMU", "DRM_HYPERV",
    "DRM_MGAG200", "DRM_QXL", "DRM_VIRTIO_GPU", "DRM_VMWGFX",
    "DRM_VBOXVIDEO",
    "FB_EFI", "FB_NVIDIA", "FB_RADEON", "FB_RIVA", "FB_VESA", "FB_VGA16",
}
for name, value in sorted(values.items()):
    if value not in ("y", "m"): continue
    if (name in {"PCI", "ATA", "BLK_DEV_NVME"} or
        name.startswith(("PCI_", "PCIE", "ATA_", "SATA_", "NVME_")) or
        name in gpu):
        print(name)
PY

while IFS= read -r sym; do
  [[ -n "$sym" ]] || continue
  scripts/config --file .config --disable "$sym"
done < "$WORK/rpi2-rpi3-hardware-disable.list"

make ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
make ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" syncconfig

python3 - .config "$WORK/rpi2-rpi3-hardware-disable.list" "$HARDWARE_REPORT" <<'PY'
import re, sys
from pathlib import Path
config_path, disabled_path, report_path = map(Path, sys.argv[1:])
values = {}
for raw in config_path.read_text().splitlines():
    line = raw.strip()
    m = re.fullmatch(r"CONFIG_([A-Z0-9_]+)=(.*)", line)
    if m: values[m.group(1)] = m.group(2)
    else:
        m = re.fullmatch(r"# CONFIG_([A-Z0-9_]+) is not set", line)
        if m: values[m.group(1)] = "n"
gpu = {
    "DRM_AMDGPU", "DRM_NOUVEAU", "DRM_RADEON",
    "DRM_AST", "DRM_BOCHS", "DRM_CIRRUS_QEMU", "DRM_HYPERV",
    "DRM_MGAG200", "DRM_QXL", "DRM_VIRTIO_GPU", "DRM_VMWGFX",
    "DRM_VBOXVIDEO",
    "FB_EFI", "FB_NVIDIA", "FB_RADEON", "FB_RIVA", "FB_VESA", "FB_VGA16",
}
def forbidden(name):
    return (name in {"PCI", "ATA", "BLK_DEV_NVME"} or
            name.startswith(("PCI_", "PCIE", "ATA_", "SATA_", "NVME_")) or
            name in gpu)
active = [(n, v) for n, v in values.items()
          if v in ("y", "m") and forbidden(n)]
if active:
    for n, v in sorted(active):
        print(f"::error::Non-Raspberry-Pi hardware option remains enabled: CONFIG_{n}={v}")
    raise SystemExit(1)
disabled = [x for x in disabled_path.read_text().splitlines() if x]
with report_path.open("w") as out:
    out.write("Raspberry Pi 2/3 hardware exclusion audit\n")
    out.write("Disabled active Fedora-base options: " + str(len(disabled)) + "\n")
    out.write("PCI/PCIe, ATA/SATA, NVMe, AMDGPU, Nouveau, Radeon and PC/virtual GPU drivers disabled\n")
    out.write("SCSI and USB storage retained; DRM core / VC4 / simpledrm not blanket-disabled\n")
    out.write("\n[DISABLED OPTIONS]\n")
    out.write("".join("CONFIG_" + x + "\n" for x in disabled))
print("Hardware exclusion audit passed; disabled " + str(len(disabled)) + " active non-Pi options.")
PY

echo "===== 5.1 Validate Raspberry Pi audio and USB DAC support ====="
# The old audit incorrectly required every SND_* entry from Fedora's much
# broader config, including symbols absent from Linux 6.2.15. Validate the
# actual Pi/USB audio path instead of unrelated PC and other-SoC drivers.
for sym in SND SND_PCM SND_TIMER SND_USB SND_USB_AUDIO SND_SOC SND_BCM2835 SND_BCM2835_SOC_I2S; do
  if grep -Eq "^CONFIG_$sym=(y|m)$" .config; then
    grep -E "^CONFIG_$sym=(y|m)$" .config
  else
    echo "::error::Required Raspberry Pi/USB audio option is not enabled: CONFIG_$sym"
    exit 1
  fi
done

echo "===== 6. Verify Raspberry Pi boot hardware ====="
for sym in USB USB_DWC2 SERIAL_AMBA_PL011 SERIAL_AMBA_PL011_CONSOLE; do
  if grep -Eq "^CONFIG_$sym=(y|m)$" .config; then
    grep -E "^CONFIG_$sym=(y|m)$" .config
  else
    echo "::error::Required Pi boot/I/O symbol is not enabled: CONFIG_$sym"
    exit 1
  fi
done

echo "===== 7. Record module compression choice without overriding it ====="
grep -E '^CONFIG_MODULE_COMPRESS(_NONE|_GZIP|_XZ|_ZSTD)?=y$' .config || true

echo "===== 8. Set exact Fedora kernel release ====="
LOCAL_SUFFIX="$(printf '%s' "$KERNEL_RELEASE" | sed 's/^6\.2\.15//')"
[[ "$LOCAL_SUFFIX" == "-215.fc36.armv7hl" ]] || {
  echo "::error::Unexpected kernel localversion suffix: $LOCAL_SUFFIX"
  exit 1
}
printf '%s\n' "$LOCAL_SUFFIX" > localversion

CONFIG_LOCALVERSION="$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' .config)"
[[ -z "$CONFIG_LOCALVERSION" ]] || {
  echo "::error::CONFIG_LOCALVERSION must be empty."
  exit 1
}
SETLOCALVERSION_OUTPUT="$(bash scripts/setlocalversion "$SRC")"
[[ "$SETLOCALVERSION_OUTPUT" == "$LOCAL_SUFFIX" ]] || {
  echo "::error::setlocalversion mismatch: $SETLOCALVERSION_OUTPUT"
  exit 1
}
ACTUAL_RELEASE="$(make -s ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" kernelrelease)"
[[ "$ACTUAL_RELEASE" == "$KERNEL_RELEASE" ]] || {
  echo "::error::Kernel release mismatch: expected $KERNEL_RELEASE got $ACTUAL_RELEASE"
  exit 1
}

cp .config "$GITHUB_WORKSPACE/output-rpi2-rpi3-v4.2.config"
cp localversion "$GITHUB_WORKSPACE/output-localversion"

{
  echo "Raspberry Pi 2/3 Fedora ARMv7 configuration audit"
  echo "Base: repository sources/kernel-srpm/kernel-armv7hl-fedora.config"
  echo "Pi reference: official bcm2709_defconfig + matching 6.2.15 bcm2835_defconfig"
  echo "Kernel release: $ACTUAL_RELEASE"
  echo
  echo "=== Diretta ABI settings ==="
  grep -E '^(CONFIG_(ARCH_BCM2835|ARCH_MULTI_V7|AEABI|SMP|PREEMPT|PREEMPT_RT|MODULES|MODULE_UNLOAD|MODVERSIONS|HARDENED_USERCOPY|FORTIFY_SOURCE|HIGHMEM|NEON))=' .config || true
  echo
  echo "=== Pi boot and I/O settings ==="
  grep -E '^(CONFIG_(MMC|MMC_BLOCK|MMC_BCM2835|USB|USB_DWC2|USB_LAN78XX|USB_NET_SMSC95XX|SERIAL_AMBA_PL011|I2C_BCM|SPI_BCM|SPI_SPIDEV))=' .config || true
  echo
  echo "=== Module compression (inherited from repository config) ==="
  grep -E '^CONFIG_MODULE_COMPRESS(_NONE|_GZIP|_XZ|_ZSTD)?=y$' .config || true
  echo
  echo "=== Pi config intersection report ==="
  cat "$PI_REPORT"
  echo
  echo "=== Final config SHA256 ==="
  sha256sum .config
} | tee "$GITHUB_WORKSPACE/rpi2-rpi3-v4.2-config-report.txt"

{
  echo "RPi hardware support after Fedora-base intersection"
  grep -E '^(CONFIG_(ARCH_BCM2835|ARCH_MULTI_V7|MMC|MMC_BLOCK|MMC_BCM2835|USB|USB_DWC2|USB_LAN78XX|USB_NET_SMSC95XX|SERIAL_AMBA_PL011|I2C_BCM|SPI_BCM|SPI_SPIDEV|GPIO_BCM|DRM_VC4|VCHIQ))=' .config || true
  echo
  echo "The list contains only options supported by the source and present in the repository Fedora config."
} >> "$HARDWARE_REPORT"
cp "$PI_REPORT" "$GITHUB_WORKSPACE/rpi2-rpi3-intersection-report.txt"
echo "Kconfig passed: Fedora ARMv7 base + supported Pi hardware intersection + A20 ABI: $ACTUAL_RELEASE"
