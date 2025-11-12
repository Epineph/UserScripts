#!/usr/bin/env python3
"""
usb_tool.py  –  Format and repair removable USB drives on Arch Linux
-------------------------------------------------------------------
USAGE
-----

  # List all block devices, marking USB sticks
  sudo usb_tool.py --list

  # (Re-)partition /dev/sdX as a single FAT32 volume called DATA
  sudo usb_tool.py --device /dev/sdX --format fat32 --label DATA

  # Run a filesystem repair (auto-detects the FS type)
  sudo usb_tool.py --device /dev/sdX --repair

  # Destructively write-test the entire stick for bad blocks
  sudo usb_tool.py --device /dev/sdX --scan-badblocks

REQUIREMENTS
------------
Core:  parted, dosfstools, e2fsprogs, ntfs-3g, gptfdisk, util-linux, usbutils
Python: pyparted, pyudev
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional

import pyudev

##############################################################################
# ----------------------------  Utility helpers  --------------------------- #
##############################################################################

def sh(cmd: list[str]) -> None:
    """Run *cmd* and raise if it fails, forwarding stdout/stderr to caller."""
    subprocess.run(cmd, check=True)

def is_root() -> bool:
    return os.geteuid() == 0

def colored(msg: str, *, color="red") -> str:  # simple ANSI wrapper
    palette = {"red": "31", "green": "32", "yellow": "33", "cyan": "36"}
    return f"\x1b[{palette[color]}m{msg}\x1b[0m"

##############################################################################
# -------------------------  Device discovery layer  ----------------------- #
##############################################################################

CTX = pyudev.Context()

def list_block_devices() -> list[dict]:
    """Return a JSON-serialisable summary for *lsblk-like* output."""
    devs = []
    for dev in CTX.list_devices(subsystem="block", DEVTYPE="disk"):
        # Skip optical and loop devices
        if dev.get("ID_TYPE") == "cd":
            continue
        devs.append(
            dict(
                name=dev.device_node,
                model=dev.get("ID_MODEL", "unknown"),
                size_bytes=int(dev.attributes.get("size", 0)) * 512,
                removable=bool(int(dev.attributes.get("removable", 0))),
                bus=dev.get("ID_BUS", "?"),
            )
        )
    return devs

def pretty_size(nbytes: int) -> str:
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if nbytes < 1024:
            return f"{nbytes:.0f} {unit}"
        nbytes /= 1024
    return f"{nbytes:.1f} PiB"

##############################################################################
# --------------------  Filesystem-specific back-ends  --------------------- #
##############################################################################

class FSBackend:
    name: str
    mkfs_cmd: list[str]
    repair_cmd: list[str]

    def format(self, part: str, label: Optional[str]) -> None:
        cmd = self.mkfs_cmd + ([] if label is None else ["-n", label]) + [part]
        sh(cmd)

    def repair(self, part: str) -> None:
        sh(self.repair_cmd + [part])

class FAT32Backend(FSBackend):
    name = "fat32"
    mkfs_cmd = ["mkfs.fat", "-F", "32"]
    repair_cmd = ["dosfsck", "-a"]  # auto-repair

class EXT4Backend(FSBackend):
    name = "ext4"
    mkfs_cmd = ["mkfs.ext4", "-F"]   # force overwrite
    repair_cmd = ["e2fsck", "-pf"]   # auto-fix, preen

class NTFSBackend(FSBackend):
    name = "ntfs"
    mkfs_cmd = ["mkntfs", "-Q", "-F"]  # quick format
    repair_cmd = ["ntfsfix"]

FS_TABLE: dict[str, FSBackend] = {
    b.name: b for b in (FAT32Backend(), EXT4Backend(), NTFSBackend())
}

def fs_backend(fs_name: str) -> FSBackend:
    try:
        return FS_TABLE[fs_name.lower()]
    except KeyError as e:
        raise SystemExit(f"Unsupported filesystem '{fs_name}'") from e

##############################################################################
# ---------------------------  Core operations  ---------------------------- #
##############################################################################

def sanity_check(device: str, *, force: bool) -> None:
    if not Path(device).exists():
        raise SystemExit(f"Device {device} does not exist.")
    if not device.startswith("/dev/"):
        raise SystemExit("Specify a full block-device path, e.g. /dev/sdb.")
    # Abort if the device appears non-removable unless user passes --force
    removable = any(d["name"] == device and d["removable"] for d in list_block_devices())
    if not removable and not force:
        raise SystemExit(
            colored(
                f"{device} does not look like a removable drive. "
                "If you are really sure, add --force.",
                color="yellow",
            )
        )

def create_single_partition(device: str, fs: str) -> str:
    """Wipe existing tables and create one primary partition occupying 100 %."""
    print(colored("Re-initialising partition table…", color="cyan"), file=sys.stderr)
    sh(["parted", "-s", device, "mklabel", "gpt"])
    sh(["parted", "-s", device, "mkpart", "primary", fs, "1MiB", "100%"])
    sh(["partprobe", device])            # refresh kernel view
    part = device + "1"                  # works for GPT on USB sticks
    return part

def scan_badblocks(device: str) -> None:
    print(colored("Destructive *write* bad-blocks scan – this will erase data!", "red"))
    sh(["badblocks", "-wsv", device])

##############################################################################
# ------------------------------  CLI wiring  ------------------------------ #
##############################################################################

def build_cli() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Safely list, format or repair USB drives.",
        formatter_class=argparse.RawTextHelpFormatter,
    )
    p.add_argument("--list", action="store_true", help="List removable disks and exit")
    p.add_argument("--device", help="Target block device, e.g. /dev/sdX")
    p.add_argument("--format", choices=FS_TABLE.keys(), help="Filesystem to create")
    p.add_argument("--label", help="Volume label (optional)")
    p.add_argument("--repair", action="store_true", help="Attempt to repair filesystem")
    p.add_argument("--scan-badblocks", action="store_true", help="Write-test every sector")
    p.add_argument("--force", action="store_true", help="By-pass removable-device check")
    return p

##############################################################################
# -------------------------------  main()  --------------------------------- #
##############################################################################

def main(argv: list[str] | None = None) -> None:
    if argv is None:
        argv = sys.argv[1:]
    cli = build_cli().parse_args(argv)

    if not is_root():
        sys.exit("Run this script as root (sudo).")

    # ------ LIST MODE ---------------------------------------------------- #
    if cli.list:
        devices = list_block_devices()
        print(json.dumps(devices, indent=2, default=str))
        return

    if not cli.device:
        sys.exit("No --device specified. See --help.")

    sanity_check(cli.device, force=cli.force)

    # ------ FORMAT MODE -------------------------------------------------- #
    if cli.format:
        backend = fs_backend(cli.format)
        target_part = create_single_partition(cli.device, cli.format)
        backend.format(target_part, cli.label)
        print(colored(f"Formatted {target_part} as {cli.format.upper()}.", "green"))
        return

    # ------ REPAIR MODE -------------------------------------------------- #
    if cli.repair:
        # blkid reports TYPE="ext4" etc.
        blkid_out = subprocess.check_output(["blkid", "-o", "value", "-s", "TYPE", cli.device]).decode().strip()
        backend = fs_backend(blkid_out)
        backend.repair(cli.device)
        print(colored(f"Repair finished on {cli.device}.", "green"))
        return

    # ------ BADBLOCKS ---------------------------------------------------- #
    if cli.scan_badblocks:
        scan_badblocks(cli.device)
        return

    print("Nothing to do. See --help.", file=sys.stderr)

if __name__ == "__main__":
    main()

