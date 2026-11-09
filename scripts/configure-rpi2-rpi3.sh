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

echo "===== 2.1 SD/MMC options are checked in the advisory hardware report ====="
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

echo "===== Pi hardware configuration completeness is advisory ====="
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

echo "===== 5. Apply Raspberry Pi 2/3 hardware-only driver profile ====="
# Keep Fedora ARMv7 as the unique base .config, but prune large groups of
# non-target hardware drivers. This is a profile, not a hard completeness test:
# missing/renamed symbols are reported and do not stop the build.
python3 - "$SRC" .config "$WORK/rpi2-rpi3-hardware-disable.list" "$HARDWARE_REPORT" <<'PY'
import re
import sys
from pathlib import Path

src, config_path, disable_path, report_path = map(Path, sys.argv[1:])
values = {}
for raw in config_path.read_text(errors="replace").splitlines():
    line = raw.strip()
    m = re.fullmatch(r"CONFIG_([A-Z0-9_]+)=(.*)", line)
    if m:
        values[m.group(1)] = m.group(2)
        continue
    m = re.fullmatch(r"# CONFIG_([A-Z0-9_]+) is not set", line)
    if m:
        values[m.group(1)] = "n"

# Map Kconfig symbols to the source-tree areas that define them. Scanning all
# Kconfig files is more reliable than guessing symbol prefixes alone.
symbol_paths = {}
roots = [src / "drivers", src / "sound", src / "arch" / "arm"]
for root in roots:
    if not root.exists():
        continue
    for kfile in root.rglob("Kconfig*"):
        if not kfile.is_file():
            continue
        rel = kfile.relative_to(src).as_posix()
        try:
            lines = kfile.read_text(errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            m = re.match(r"^\s*(?:menu)?config\s+([A-Z0-9_]+)\b", line)
            if m:
                symbol_paths.setdefault(m.group(1), set()).add(rel)

# These are the hardware interfaces used by Pi 2/3 or the common infrastructure
# required to reach them. Keep only these in otherwise-pruned driver groups.
keep = {
    # BCM2835/BCM2836/BCM2837 platform and VideoCore
    "ARCH_BCM2835", "ARCH_BCM", "ARCH_MULTI_V7", "ARCH_MULTIPLATFORM",
    "BCM2835_MBOX", "BCM2835_POWER", "BCM2835_THERMAL", "BCM2835_WDT",
    "BCM2835_VCHIQ", "BCM2835_VCHIQ_MMAL", "VCHIQ",
    "BCM2835_DMA", "BCM2835_RNG", "HW_RANDOM_BCM2835",
    "BCM2835_TIMER", "CLK_BCM2835", "CLK_RASPBERRYPI",
    "RASPBERRYPI_FIRMWARE", "RASPBERRYPI_POWER",
    "GPIO_RASPBERRYPI_EXP", "SENSORS_RASPBERRYPI_HWMON",
    "REGULATOR_RASPBERRYPI_TOUCHSCREEN_ATTINY",
    "TOUCHSCREEN_RASPBERRYPI_FW", "DRM_PANEL_RASPBERRYPI_TOUCHSCREEN",
    "PWM_RASPBERRYPI_POE", "PWM_BCM2835", "VIDEO_BCM2835",
    "DRM", "DRM_KMS_HELPER", "DRM_GEM_SHMEM_HELPER", "DRM_VC4",
    "DRM_DISPLAY_HELPER", "DRM_PANEL", "DRM_BRIDGE",
    "MEDIA_SUPPORT", "MEDIA_CAMERA_SUPPORT", "MEDIA_CONTROLLER",
    "MEDIA_PLATFORM_SUPPORT", "MEDIA_COMMON_OPTIONS", "MEDIA_ATTACH",
    "VIDEO_DEV", "VIDEO_V4L2", "VIDEO_V4L2_I2C",
    "VIDEO_V4L2_SUBDEV_API", "VIDEO_BCM2835", "VIDEO_OV5647",
    "VIDEO_IMX219", "V4L2_FWNODE", "V4L2_ASYNC",
    "VIDEOBUF2_CORE", "VIDEOBUF2_V4L2", "VIDEOBUF2_MEMOPS",
    "VIDEOBUF2_VMALLOC", "VIDEOBUF2_DMA_CONTIG",
    "MEDIA_CONTROLLER_REQUEST_API",
    # SD/MMC, USB host/storage and Pi 2/3 USB Ethernet
    "MMC", "MMC_BLOCK", "MMC_BCM2835", "MMC_SDHCI", "MMC_SDHCI_PLTFM",
    "USB", "USB_COMMON", "USB_SUPPORT", "USB_DWC2", "USB_DWCOTG",
    "USB_STORAGE", "USB_UAS", "USB_HID", "USB_USBNET", "USB_NET_DRIVERS",
    "USB_NET_SMSC95XX", "USB_LAN78XX",
    # Pi 3 on-board Broadcom Wi-Fi and Bluetooth
    "BRCMFMAC", "BRCMFMAC_SDIO", "BRCMFMAC_PROTO_BCDC",
    "BRCMFMAC_PROTO_MSGBUF", "BRCMUTIL", "CFG80211", "MAC80211",
    "WLAN", "WLAN_VENDOR_BROADCOM",
    "BT", "BT_BCM", "BT_HCIUART", "BT_HCIUART_BCM",
    # Pi SoC buses, pins, clocks and serial console
    "I2C", "I2C_CHARDEV", "I2C_BCM2835",
    "SPI", "SPI_BCM2835", "SPI_BCM2835AUX", "SPI_SPIDEV",
    "GPIOLIB", "GPIO_SYSFS", "PINCTRL", "PINCTRL_BCM2835",
    "SERIAL_AMBA_PL011", "SERIAL_AMBA_PL011_CONSOLE",
    "SERIAL_8250", "SERIAL_8250_BCM2835AUX",
    "DMADEVICES", "DMA_BCM2835", "MAILBOX", "BCM2835_MBOX",
    "PWM", "PWM_BCM2835", "THERMAL", "BCM2835_THERMAL",
    "WATCHDOG", "BCM2835_WDT",
    # Audio: BCM2835/I2S and generic USB Audio Class
    "SND", "SND_PCM", "SND_TIMER", "SND_HWDEP", "SND_RAWMIDI",
    "SND_SOC", "SND_BCM2835", "SND_BCM2835_SOC_I2S",
    "SND_SOC_BCM2835_I2S", "SND_USB", "SND_USB_AUDIO",
    # Common generic interfaces required by the system
    "INPUT", "INPUT_EVDEV", "INPUT_KEYBOARD", "INPUT_MOUSE",
    "INPUT_TOUCHSCREEN", "HID", "HID_GENERIC", "USB_HID", "HWMON",
    "SCSI", "BLK_DEV_SD", "USB_STORAGE", "USB_UAS",
    "NET", "INET", "PACKET", "UNIX", "NETDEVICES",
    "EXT4_FS", "VFAT_FS", "FAT_FS", "SQUASHFS", "OVERLAY_FS",
}

def prune(rel, sym):
    # Explicitly preserve Pi drivers even if their Kconfig lives in a broad tree.
    if sym in keep:
        return False

    # Root Kconfig files mix generic frameworks with SoC controllers.
    # Keep the generic core plus the BCM2835/Pi-specific implementations.
    root_allow = {
        "drivers/clk/Kconfig": {"COMMON_CLK", "CLKDEV_LOOKUP", "CLK_BCM2835", "CLK_RASPBERRYPI"},
        "drivers/pinctrl/Kconfig": {"PINCTRL", "PINMUX", "PINCONF", "GENERIC_PINCONF", "PINCTRL_BCM2835"},
        "drivers/gpio/Kconfig": {"GPIOLIB", "GPIOLIB_IRQCHIP", "GPIO_SYSFS", "GPIO_CDEV", "GPIO_CDEV_V1", "GPIO_RASPBERRYPI_EXP", "GPIO_BCM2835", "GPIO_REGMAP"},
        "drivers/i2c/busses/Kconfig": {"I2C_BCM2835"},
        "drivers/spi/Kconfig": {"SPI", "SPI_MASTER", "SPI_MEM", "SPI_BCM2835", "SPI_BCM2835AUX", "SPI_SPIDEV"},
        "drivers/mmc/host/Kconfig": {"MMC_BCM2835"},
        "drivers/tty/serial/Kconfig": {"SERIAL_CORE", "SERIAL_AMBA_PL011", "SERIAL_AMBA_PL011_CONSOLE", "SERIAL_8250", "SERIAL_8250_CONSOLE", "SERIAL_8250_BCM2835AUX"},
        "drivers/thermal/Kconfig": {"THERMAL", "THERMAL_OF", "THERMAL_HWMON", "THERMAL_DEFAULT_GOV_STEP_WISE", "THERMAL_GOV_STEP_WISE", "BCM2835_THERMAL"},
        "drivers/watchdog/Kconfig": {"WATCHDOG", "WATCHDOG_CORE", "WATCHDOG_HANDLE_BOOT_ENABLED", "BCM2835_WDT"},
        "drivers/pwm/Kconfig": {"PWM", "PWM_SYSFS", "PWM_BCM2835", "PWM_RASPBERRYPI_POE"},
        "drivers/mailbox/Kconfig": {"MAILBOX", "BCM2835_MBOX"},
        "drivers/dma/Kconfig": {"DMADEVICES", "DMA_ENGINE", "DMA_VIRTUAL_CHANNELS", "DMA_OF", "DMA_SHARED_BUFFER", "DMA_BCM2835"},
    }
    if rel in root_allow:
        return sym not in root_allow[rel]

    # Retain BCM clock/pinctrl and the BCM2835 auxiliary UART only.
    if rel.startswith("drivers/clk/"):
        return not (rel.startswith("drivers/clk/bcm/") and sym in {"CLK_BCM2835", "CLK_RASPBERRYPI"})
    if rel.startswith("drivers/pinctrl/"):
        return not (rel.startswith("drivers/pinctrl/bcm/") and sym == "PINCTRL_BCM2835")
    if rel.startswith("drivers/tty/serial/"):
        return not (rel.startswith("drivers/tty/serial/8250/") and sym == "SERIAL_8250_BCM2835AUX")

    # Keep the BCM2835 camera pipeline and the Pi camera sensors (OV5647 /
    # IMX219); drop unrelated USB capture cards, DVB tuners and radio devices.
    if rel.startswith("drivers/media/"):
        return sym not in {
            "MEDIA_SUPPORT", "MEDIA_CAMERA_SUPPORT", "MEDIA_CONTROLLER",
            "MEDIA_PLATFORM_SUPPORT", "MEDIA_COMMON_OPTIONS", "MEDIA_ATTACH",
            "VIDEO_DEV", "VIDEO_V4L2", "VIDEO_V4L2_I2C",
            "VIDEO_V4L2_SUBDEV_API", "VIDEO_BCM2835", "VIDEO_OV5647",
            "VIDEO_IMX219", "V4L2_FWNODE", "V4L2_ASYNC",
            "VIDEOBUF2_CORE", "VIDEOBUF2_V4L2", "VIDEOBUF2_MEMOPS",
            "VIDEOBUF2_VMALLOC", "VIDEOBUF2_DMA_CONTIG",
            "MEDIA_CONTROLLER_REQUEST_API",
        }

    # Pi 2/3 Ethernet is attached through the USB hub: SMSC95xx on Pi 2,
    # LAN78xx on Pi 3. There is no onboard PCI/SoC Ethernet MAC.
    if rel.startswith("drivers/net/ethernet/"):
        return True
    if rel.startswith("drivers/net/usb/"):
        return sym not in {"USB_USBNET", "USB_NET_SMSC95XX", "USB_LAN78XX"}
    if rel.startswith("drivers/net/wireless/"):
        return not (rel.startswith("drivers/net/wireless/broadcom/brcm80211/") and
                    sym in {"BRCMFMAC", "BRCMFMAC_SDIO", "BRCMFMAC_PROTO_BCDC",
                            "BRCMFMAC_PROTO_MSGBUF", "BRCMUTIL"})
    if rel.startswith(("drivers/net/can/", "drivers/net/hamradio/",
                       "drivers/net/wan/", "drivers/net/wwan/",
                       "drivers/net/atm/", "drivers/net/irda/")):
        return True

    # USB host controller: keep only the DWC controllers used by BCM boards.
    if rel.startswith("drivers/usb/host/"):
        return sym not in {"USB_DWC2", "USB_DWCOTG"}
    if rel.startswith(("drivers/usb/serial/", "drivers/usb/gadget/",
                       "drivers/usb/misc/", "drivers/usb/atm/")):
        return True

    # Keep VC4 (Pi 2/3 display) and VCHIQ (VideoCore services); remove other
    # discrete, virtual and unrelated SoC GPU implementations.
    if rel.startswith("drivers/gpu/drm/"):
        if rel in {"drivers/gpu/drm/Kconfig", "drivers/gpu/drm/Makefile"}:
            return False
        return not (rel.startswith("drivers/gpu/drm/vc4/") and sym.startswith("DRM_"))
    if rel.startswith("drivers/gpu/"):
        return True
    if rel.startswith("drivers/staging/"):
        return not rel.startswith("drivers/staging/vc04_services/")

    # Non-Pi storage and expansion buses/controllers.
    if rel.startswith(("drivers/ata/", "drivers/nvme/", "drivers/pci/",
                       "drivers/cxl/", "drivers/firewire/", "drivers/pcmcia/",
                       "drivers/infiniband/", "drivers/mtd/", "drivers/md/",
                       "drivers/isdn/", "drivers/atm/")):
        return True
    if rel.startswith("drivers/scsi/") and rel not in {
        "drivers/scsi/Kconfig", "drivers/scsi/Makefile"
    }:
        return True

    # Non-essential peripheral classes that account for many modules.
    if rel.startswith(("drivers/iio/", "drivers/w1/",
                       "drivers/input/joystick/", "drivers/input/misc/")):
        return True
    if rel.startswith("drivers/hwmon/"):
        return sym != "SENSORS_RASPBERRYPI_HWMON"
    if rel.startswith("drivers/input/touchscreen/"):
        return sym != "TOUCHSCREEN_RASPBERRYPI_FW"
    if rel.startswith("drivers/rtc/"):
        return sym not in {
            "RTC_CLASS", "RTC_HCTOSYS", "RTC_HCTOSYS_DEVICE", "RTC_SYSTOHC",
            "RTC_NVMEM", "RTC_INTF_SYSFS", "RTC_INTF_PROC", "RTC_INTF_DEV",
        }
    if rel.startswith("drivers/hid/"):
        if rel == "drivers/hid/Kconfig":
            return False
        return not rel.startswith("drivers/hid/usbhid/")

    # Do not build other SoC audio codec/CPU-DAI drivers or PCI/ISA sound cards.
    if rel.startswith("sound/soc/"):
        if rel in {"sound/soc/Kconfig", "sound/soc/Makefile"}:
            return False
        return not rel.startswith("sound/soc/bcm/")
    if rel.startswith(("sound/pci/", "sound/isa/")):
        return True
    if rel.startswith("sound/usb/") and rel not in {
        "sound/usb/Kconfig", "sound/usb/Makefile"
    }:
        return True

    # Keep BCM ARM machine support only; disable unrelated ARM SoC machine code.
    if rel.startswith("arch/arm/mach-"):
        return not rel.startswith("arch/arm/mach-bcm/")

    return False

disabled = []
not_mapped = []
for sym, value in sorted(values.items()):
    if value not in ("y", "m"):
        continue
    paths = symbol_paths.get(sym, set())
    if not paths:
        continue
    if any(prune(path, sym) for path in paths):
        disabled.append(sym)
    elif any(path.startswith(("drivers/", "sound/")) for path in paths):
        # Record retained hardware drivers for review; not a gate.
        pass

disable_path.parent.mkdir(parents=True, exist_ok=True)
disable_path.write_text("".join(sym + "\n" for sym in disabled))
report_path.parent.mkdir(parents=True, exist_ok=True)
with report_path.open("w") as out:
    out.write("Raspberry Pi 2/3 hardware profile audit (advisory; not a build gate)\n")
    out.write("Base .config: repository Fedora ARMv7 config\n")
    out.write("Pi target: BCM2836 / BCM2837, Raspberry Pi 2 / Pi 3\n")
    out.write("Disabled active non-target driver symbols: " + str(len(disabled)) + "\n")
    out.write("Policy: retain Pi USB DWC, SD/MMC, USB Ethernet, Pi 3 Broadcom SDIO Wi-Fi/BT,\n")
    out.write("BCM2835 buses, GPIO, PL011, VC4/VCHIQ and Pi/USB audio; prune unrelated\n")
    out.write("media/DVB, non-Pi network, USB serial/gadget/misc, other GPU/SoC and\n")
    out.write("non-Pi storage/peripheral drivers.\n\n[DISABLED SYMBOLS]\n")
    out.writelines("CONFIG_" + sym + "\n" for sym in disabled)

print("Hardware profile: disabling " + str(len(disabled)) +
      " active symbols in non-Pi driver groups.")
PY

while IFS= read -r sym; do
  [[ -n "$sym" ]] || continue
  scripts/config --file .config --disable "$sym"
done < "$WORK/rpi2-rpi3-hardware-disable.list"

make ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
make ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" syncconfig

echo "===== 5.1 Advisory Pi hardware / audio audit (missing entries do not fail) ====="
python3 - .config "$HARDWARE_REPORT" <<'PY'
import re, sys
from pathlib import Path
config_path, report_path = map(Path, sys.argv[1:])
values = {}
for raw in config_path.read_text(errors="replace").splitlines():
    line = raw.strip()
    m = re.fullmatch(r"CONFIG_([A-Z0-9_]+)=(.*)", line)
    if m: values[m.group(1)] = m.group(2)
    else:
        m = re.fullmatch(r"# CONFIG_([A-Z0-9_]+) is not set", line)
        if m: values[m.group(1)] = "n"

checks = {
    "Pi architecture": ["ARCH_BCM2835", "ARCH_MULTI_V7", "AEABI", "SMP"],
    "SD/MMC boot": ["MMC", "MMC_BLOCK", "MMC_BCM2835"],
    "USB host/storage": ["USB", "USB_DWCOTG", "USB_DWC2", "USB_STORAGE", "USB_UAS"],
    "Pi 2/3 Ethernet": ["USB_NET_SMSC95XX", "USB_LAN78XX"],
    "Pi 3 onboard Wi-Fi/BT": ["BRCMFMAC", "BRCMFMAC_SDIO", "BT_HCIUART", "BT_HCIUART_BCM"],
    "Pi SoC I/O": ["I2C_BCM2835", "SPI_BCM2835", "PINCTRL_BCM2835", "SERIAL_AMBA_PL011"],
    "VideoCore/display": ["DRM_VC4", "BCM2835_VCHIQ"],
    "Audio": ["SND", "SND_PCM", "SND_TIMER", "SND_BCM2835",
              "SND_BCM2835_SOC_I2S", "SND_USB_AUDIO"],
}
lines = []
missing_total = 0
for group, symbols in checks.items():
    lines.append("[" + group + "]")
    for sym in symbols:
        value = values.get(sym, "<missing>")
        if value in ("y", "m"):
            lines.append("OK CONFIG_" + sym + "=" + value)
        else:
            missing_total += 1
            lines.append("MISSING/disabled CONFIG_" + sym + "=" + value)
    lines.append("")
with report_path.open("a") as out:
    out.write("\n[ADVISORY HARDWARE/AUDIO CHECKS]\n")
    out.write("\n".join(lines) + "\n")
    out.write("Missing or disabled advisory entries: " + str(missing_total) + "\n")
print("\n".join(lines))
print("Advisory audit complete; missing entries are reported, not fatal.")
PY

echo "===== 6. Raspberry Pi hardware checks are advisory ====="
echo "The final config and missing Pi driver symbols are recorded in the audit report."
echo "Build continues; actual kernel/DTB build and Diretta ABI checks remain the hard gates."

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
