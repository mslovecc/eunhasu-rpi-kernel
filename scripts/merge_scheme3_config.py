#!/usr/bin/env python3
"""Deterministic Scheme 3 merge: A20 Eunhasu baseline + BCM2709 + Diretta ABI."""
from __future__ import annotations
import argparse, re, subprocess
from pathlib import Path

ACTIVE = re.compile(r'^CONFIG_([A-Z0-9_]+)=(.*)$')
UNSET = re.compile(r'^# CONFIG_([A-Z0-9_]+) is not set$')
ALLWINNER = re.compile(
    r'^(ARCH_SUNXI|MACH_SUN[0-9]+I|SUNXI|SUN[0-9]+I|AXP[0-9A-Z_]*|'
    r'ALLWINNER|MFD_AXP|REGULATOR_AXP|POWER_RESET_SUNXI|PINCTRL_SUNXI|'
    r'I2C_SUN[0-9A-Z_]*|SPI_SUN[0-9A-Z_]*|MMC_SUN[0-9A-Z_]*|'
    r'RTC_DRV_SUN[0-9A-Z_]*|PWM_SUN[0-9A-Z_]*|THERMAL_SUN[0-9A-Z_]*)'
)

def parse(path: Path):
    active, unset = {}, set()
    for line in path.read_text().splitlines():
        m = ACTIVE.match(line)
        if m:
            active[m.group(1)] = m.group(2)
            continue
        m = UNSET.match(line)
        if m:
            unset.add(m.group(1))
    return active, unset

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--a20", required=True)
    p.add_argument("--bcm", required=True)
    p.add_argument("--boot", required=True)
    p.add_argument("--abi", required=True)
    p.add_argument("--source", required=True)
    p.add_argument("--report", required=True)
    args = p.parse_args()
    a20, bcm = Path(args.a20), Path(args.bcm)
    boot, abi, src = Path(args.boot), Path(args.abi), Path(args.source)
    a20_active, _ = parse(a20)
    bcm_active, _ = parse(bcm)

    kept, removed = [], []
    for line in a20.read_text().splitlines():
        m = ACTIVE.match(line)
        u = UNSET.match(line)
        key = m.group(1) if m else (u.group(1) if u else None)
        if key and ALLWINNER.match(key):
            removed.append(line)
            continue
        # A20's selected Allwinner platform must not survive on BCM2835.
        if key in {"ARCH_SUNXI", "MACH_SUN7I", "MACH_SUN4I", "MACH_SUN5I",
                   "MACH_SUN6I", "MACH_SUN8I", "MACH_SUN9I"}:
            removed.append(line)
            continue
        kept.append(line)
    (src / ".config").write_text("\n".join(kept) + "\n")

    # BCM entries are applied only when A20 did not actively choose a value.
    # Explicit A20 'not set' entries can be overridden for RPi hardware.
    bcm_lines, bcm_added, a20_conflicts = [], [], []
    for line in bcm.read_text().splitlines():
        m = ACTIVE.match(line)
        if not m:
            continue
        key, value = m.groups()
        if ALLWINNER.match(key):
            continue
        if key in a20_active:
            if a20_active[key] != value:
                a20_conflicts.append(f"CONFIG_{key}: A20={a20_active[key]} BCM={value}; kept A20")
            continue
        bcm_lines.append(line)
        bcm_added.append(line)
    filtered = src / ".scheme3-bcm2709.fragment"
    filtered.write_text("\n".join(bcm_lines) + "\n")

    # Boot/runtime requirements are an additive RPi layer. Existing active
    # A20 values win; unset/missing values may be enabled for the Pi.
    boot_active, _ = parse(boot)
    boot_lines, boot_conflicts = [], []
    for line in boot.read_text().splitlines():
        m = ACTIVE.match(line)
        if not m:
            continue
        key, value = m.groups()
        if key in a20_active:
            if a20_active[key] != value:
                boot_conflicts.append(f"CONFIG_{key}: A20={a20_active[key]} BOOT={value}; kept A20")
            continue
        boot_lines.append(line)
    filtered_boot = src / ".scheme3-rpi2b-boot.fragment"
    filtered_boot.write_text("\n".join(boot_lines) + "\n")

    subprocess.run([
        "bash", str(src / "scripts/kconfig/merge_config.sh"), "-m", "-r",
        str(src / ".config"), str(filtered), str(filtered_boot), str(abi)
    ], check=True)

    report = [
        "Scheme 3 configuration merge report",
        f"A20 baseline: {a20}",
        f"Raspberry Pi hardware config: {bcm}",
        "Priority: Diretta ABI > enabled A20 baseline settings > BCM2709 hardware additions",
        "A20 platform-specific Allwinner/Sunxi/AXP settings removed:",
        *(removed or ["(none)"]),
        "",
        "BCM2709 settings added because A20 had no active value:",
        *(bcm_added or ["(none)"]),
        "",
        "BCM2709 conflicts resolved in favor of active A20 settings:",
        *(a20_conflicts or ["(none)"]),
        "",
        "RPi boot/peripheral settings added:",
        *(boot_lines or ["(none)"]),
        "",
        "RPi boot/peripheral conflicts resolved in favor of active A20 settings:",
        *(boot_conflicts or ["(none)"]),
        "",
        "Diretta ABI fragment applied last:",
        abi.read_text(),
    ]
    Path(args.report).write_text("\n".join(report) + "\n")

if __name__ == "__main__":
    main()
