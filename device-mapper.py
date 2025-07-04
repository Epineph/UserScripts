#!/usr/bin/env python3
"""
device_report.py - Display detailed block device information with syntax highlighting.

This script gathers information from lsblk and blkid, computes usage
via Python's shutil.disk_usage, and presents a colored table using the
Rich library. It now safely skips pseudo-mountpoints like "[SWAP]".

Usage:
  device_report.py [--json]

Options:
  -j, --json     Output raw JSON data instead of a formatted table
  -h, --help     Show this help message and exit

Dependencies:
  - Python 3.6+
  - rich (install via `pip install rich`)
  - lsblk, blkid (standard on most Linux distributions)
"""

import argparse
import subprocess
import json
import shutil
import os                                    # ← New: for ismount()
from rich.table import Table
from rich.console import Console


def get_lsblk_data():
    """
    Invoke lsblk to get block device details in JSON format.
    Returns a list of block devices with selected fields.
    """
    output = subprocess.check_output([
        "lsblk",
        "-J",            # JSON output
        "-b",            # sizes in bytes
        "-o", "NAME,FSTYPE,UUID,SIZE,MOUNTPOINT"
    ], text=True)
    data = json.loads(output)
    return data.get("blockdevices", [])


def get_uuid(device_name):
    """
    Retrieve the UUID of a given device via blkid.
    Returns an empty string on failure.
    """
    try:
        uuid = subprocess.check_output([
            "blkid",
            "-s", "UUID",
            "-o", "value",
            f"/dev/{device_name}"
        ], text=True).strip()
        return uuid
    except subprocess.CalledProcessError:
        return ""


def format_size(num_bytes):
    """
    Convert a size in bytes to a human-readable string using binary prefixes.
    E.g., 123456789 -> '117.7M'
    """
    for unit in ["B", "K", "M", "G", "T", "P"]:
        if num_bytes < 1024:
            return f"{num_bytes:.1f}{unit}"
        num_bytes /= 1024
    return f"{num_bytes:.1f}E"


def build_table(devices, console):
    """
    Populate and return a Rich Table from the devices list.
    Recursively handles children partitions.
    """
    table = Table(show_header=True, header_style="bold cyan")
    table.add_column("DEVICE", style="dim", no_wrap=True)
    table.add_column("FSTYPE")
    table.add_column("UUID")
    table.add_column("SIZE", justify="right")
    table.add_column("USED", justify="right")
    table.add_column("AVAILABLE", justify="right")
    table.add_column("MOUNTPOINT", style="italic")

    def add_rows(dev_list):
        for d in dev_list:
            name     = d.get("name", "")
            fstype   = d.get("fstype") or ""
            uuid     = d.get("uuid") or get_uuid(name)
            size     = format_size(int(d.get("size", 0)))
            mount    = d.get("mountpoint") or ""

            # ----------------------------------------------------------------------------
            # Compute usage only for real, existing mount points.
            # os.path.ismount() returns False for "[SWAP]" or any non-mount.
            if mount and os.path.ismount(mount):
                try:
                    usage = shutil.disk_usage(mount)
                    used  = format_size(usage.used)
                    avail = format_size(usage.free)
                except (FileNotFoundError, PermissionError):
                    # In case the path becomes unavailable or is restricted.
                    used = avail = ""
            else:
                used = avail = ""
            # ----------------------------------------------------------------------------

            table.add_row(
                f"/dev/{name}",
                fstype,
                uuid,
                size,
                used,
                avail,
                mount
            )

            # Recurse into children (partitions), if any
            if d.get("children"):
                add_rows(d["children"])

    add_rows(devices)
    return table


def main():
    parser = argparse.ArgumentParser(
        description="Display detailed block device information in a colored table"
    )
    parser.add_argument(
        "-j", "--json", action="store_true",
        help="Output raw JSON data instead of formatted table"
    )
    args = parser.parse_args()

    devices = get_lsblk_data()
    if args.json:
        # Pretty-print JSON and exit
        print(json.dumps(devices, indent=2))
        return

    console = Console()
    table   = build_table(devices, console)
    console.print(table)


if __name__ == "__main__":
    main()

