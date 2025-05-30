#!/usr/bin/env python3
"""
py_multi_copy.py: Pure-Python multi-target copier with unified Rich progress, ETA, and lsblk support for disks/partitions

Reads from input file(s) or device(s), writes to one or more outputs,
and displays a single progress bar with bytes transferred, speed,
elapsed and estimated remaining time.

Supports:
  -i/--input       Regular file(s) or device input
  -d/--disk        Block device(s) (e.g. /dev/sda), shows lsblk info
  -p/--partition   Partition(s)    (e.g. /dev/sda1), shows lsblk info
  -t/--target      Output file(s); can repeat to fan out
  -b/--bs SIZE     Block size (e.g. 512, 4K, 1M, 2MiB) [default: 1MiB]
  -c/--count N     Number of blocks (overrides auto-count)
  -h/--help        Show this help and exit

Requirements:
  • Python 3.8+
  • rich (`pip install rich`)
  • lsblk (util-linux)
  • bat (optional, for pretty lsblk table)

Examples:
  # Copy a regular file into two outputs:
  sudo ./py_multi_copy.py \
    -i input.bin \
    -t out1.bin \
    -t out2.bin

  # Copy entire disk /dev/sda to two image files with 4MiB block size:
  sudo ./py_multi_copy.py \
    -d /dev/sda \
    -t sda_backup1.img \
    -t sda_backup2.img \
    -b 4M

  # Copy a single partition /dev/sda1 to an image:
  sudo ./py_multi_copy.py \
    -p /dev/sda1 \
    -t sda1.img

  # Quick test: copy first 1024 blocks of /dev/zero (1KiB blocks):
  sudo ./py_multi_copy.py \
    -i /dev/zero \
    -t test_zero.bin \
    -b 1K -c 1024

  # Debugging example: use a tiny file under 1KiB
  echo "hello world" > small.txt
  sudo ./py_multi_copy.py \
    -i small.txt \
    -t copy1.txt \
    -t copy2.txt

  # Combine count and multiple targets:
  sudo ./py_multi_copy.py \
    -d /dev/nvme0n1p1 \
    -t nvme_part1.img \
    -t mirror1.img \
    -c 2048   # copy first 2048 blocks

Testing & Debugging Tips:
  • To verify correct byte counts, use `lsblk -b /dev/...` or `stat -c%s file`.
  • For fastest throughput, match bs to device optimal block size (e.g. 4MiB).
  • Use small `-c` values with `/dev/zero` for quick loops without full-copy.
  • Run under `time` to measure real/user/sys performance:
      time sudo ./py_multi_copy.py -i /dev/zero -t out.bin -b1M -c1024

"""
import argparse
import os
import re
import shutil
import subprocess
import sys
from rich.progress import (
    Progress, TextColumn, BarColumn,
    TransferSpeedColumn, TimeElapsedColumn, TimeRemainingColumn
)
from rich.console import Console

console = Console()

def parse_size(s: str) -> int:
    """Parse integer with optional K/M/G suffix into bytes."""
    m = re.fullmatch(r"(\d+)([KkMmGg])?", s)
    if not m:
        raise argparse.ArgumentTypeError(f"Invalid size: {s}")
    val = int(m.group(1))
    suff = m.group(2)
    if suff:
        if suff.lower() == 'k': val *= 1024
        elif suff.lower() == 'm': val *= 1024**2
        elif suff.lower() == 'g': val *= 1024**3
    return val


def print_lsblk(dev: str) -> None:
    """Invoke lsblk for dev and pretty-print (bat if available)."""
    cmd = ["lsblk", "-o", "NAME,SIZE,TYPE,MOUNTPOINT", dev]
    try:
        out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    except subprocess.CalledProcessError as e:
        console.print(f"[red]ERROR[/] lsblk failed: {e}")
        sys.exit(1)
    if shutil.which("bat"):
        bat = subprocess.Popen([
            "bat", "--paging=never", "--style=header,grid"
        ], stdin=subprocess.PIPE, text=True)
        bat.communicate(out)
    else:
        console.print(out)


def get_dev_size(dev: str) -> int:
    """Return device size in bytes via lsblk."""
    try:
        out = subprocess.run([
            "lsblk", "-b", "-dn", "-o", "SIZE", dev
        ], check=True, capture_output=True, text=True).stdout
        return int(out.strip())
    except Exception as e:
        console.print(f"[red]ERROR[/] cannot determine size of {dev}: {e}")
        sys.exit(1)


def copy_and_update(src: str, dst: str, bs: int, progress: Progress, task_id: int) -> None:
    """Copy src → dst in blocks of bs, updating global progress task."""
    try:
        with open(src, 'rb') as inf, open(dst, 'wb') as outf:
            while True:
                chunk = inf.read(bs)
                if not chunk:
                    break
                outf.write(chunk)
                progress.update(task_id, advance=len(chunk))
    except Exception as e:
        console.print(f"[red]ERROR[/] copying {src} to {dst}: {e}")
        sys.exit(1)


def main():
    p = argparse.ArgumentParser(
        prog="py_multi_copy.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__
    )
    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument('-i', '--input', action='append', dest='input_files', help='Input file(s)')
    group.add_argument('-d', '--disk', action='append', dest='disk_devs', help='Disk device(s)')
    group.add_argument('-p', '--partition', action='append', dest='part_devs', help='Partition device(s)')
    p.add_argument('-t', '--target', action='append', required=True, help='Output target(s)')
    p.add_argument('-b', '--bs', type=parse_size, default=parse_size('1M'), help='Block size')
    p.add_argument('-c', '--count', type=int, help='Number of blocks (override)')
    args = p.parse_args()

    # Build list of input devices/files, and optionally print lsblk for disks/parts
    sources = []  # tuples of (path, auto_size_flag)
    if args.input_files:
        for f in args.input_files:
            sources.append((f, False))
    else:
        for dev in (args.disk_devs or []):
            print_lsblk(dev)
            sources.append((dev, True))
        for dev in (args.part_devs or []):
            print_lsblk(dev)
            sources.append((dev, True))

    bs = args.bs
    jobs = []  # list of (src, dst, size_bytes)
    for src, auto in sources:
        if auto:
            size = get_dev_size(src)
        else:
            try:
                size = os.stat(src).st_size
            except:
                size = None
        for tgt in args.target:
            jobs.append((src, tgt, size))

    # Compute total bytes for progress
    if args.count is not None:
        total_bytes = args.count * bs * len(jobs)
    else:
        total_bytes = sum(sz if sz is not None else 0 for _,_,sz in jobs)

    # Setup unified progress bar
    progress = Progress(
        TextColumn("[bold blue]Total"),
        BarColumn(bar_width=None),
        TextColumn("{task.percentage:>3.0f}%"),
        TransferSpeedColumn(),
        TimeElapsedColumn(),
        TimeRemainingColumn(),
        console=console,
        refresh_per_second=10,
        transient=True,
    )
    total_task = progress.add_task("total", total=total_bytes)

    # Execute copies
    with progress:
        for src, tgt, sz in jobs:
            copy_and_update(src, tgt, bs, progress, total_task)

    console.print("[green]All operations completed successfully.[/]")

if __name__ == '__main__':
    main()

