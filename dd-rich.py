#!/usr/bin/env python3
"""
dd_rich.py: Rich-enhanced wrapper for `dd` copying

Usage:
  dd_rich.py [OPTIONS] <INPUT> <TARGET> [TARGET...]

Description:
  Recursively copy raw data from INPUT (file or device) to one or more TARGETs using `dd`,
  with a live Rich progress bar showing:
    • Bytes transferred
    • Transfer speed
    • Elapsed time
    • Estimated remaining time

Options:
  -b, --bs SIZE       Block size (supports arithmetic and suffixes: M=MiB, G=GiB).
                      Examples: 512, 4M, 2*1024M, (1+1)G
  -c, --count COUNT   Number of blocks to copy (arithmetic expressions OK).
                      Interpreted in units of BS. Examples: 1024, 1M, 512*2
  -h, --help          Show this help message and exit

Examples:
  # Copy entire /dev/sda to two image files with 4 MiB blocks:
  sudo dd_rich.py -b4M /dev/sda backup1.img backup2.img

  # Copy first 2048 blocks of 1 MiB:
  sudo dd_rich.py -c2048 -M /dev/zero /tmp/zeros.img

  # Use a complex expression for block size:
  sudo dd_rich.py -b"(2+2)M" /dev/sdb image.img
"""
import argparse
import os
import re
import subprocess
import sys
from ast import literal_eval, parse, Expression
from rich.progress import Progress, BarColumn, TransferSpeedColumn, TimeElapsedColumn, TimeRemainingColumn, TextColumn
from rich.console import Console

console = Console()

def parse_numeric(expr: str) -> int:
    """Evaluate an arithmetic expression with optional M/G suffix."""
    m = re.fullmatch(r"\s*([0-9+\-*/() ]+)([MmGg])?[iI]?[Bb]?\s*", expr)
    if not m:
        raise argparse.ArgumentTypeError(f"Invalid expression '{expr}'")
    body, suff = m.group(1), m.group(2)
    try:
        node = parse(body, mode='eval')
        value = literal_eval(node)
    except Exception:
        raise argparse.ArgumentTypeError(f"Cannot evaluate '{body}'")
    if not isinstance(value, int) or value < 0:
        raise argparse.ArgumentTypeError(f"Result not non-negative integer: {value}")
    if suff:
        factor = 1024**2 if suff.lower()=='m' else 1024**3
        value *= factor
    return value


def run_dd(src: str, dst: str, bs: int, count: int | None):
    cmd = ["dd", f"if={src}", f"of={dst}", f"bs={bs}", "status=progress"]
    if count is not None:
        cmd.append(f"count={count}")
    console.log(f"[blue]Executing: {' '.join(cmd)}")
    proc = subprocess.Popen(cmd, stderr=subprocess.PIPE, text=True)

    progress = Progress(
        TextColumn("[bold blue]Copy"),
        BarColumn(bar_width=None),
        TransferSpeedColumn(),
        TimeElapsedColumn(),
        TimeRemainingColumn(),
        console=console,
        transient=True
    )
    task = progress.add_task("", total=None)
    with progress:
        for line in proc.stderr:
            m = re.match(r"^(\d+)", line)
            if m:
                progress.update(task, completed=int(m.group(1)))
        proc.wait()
    if proc.returncode != 0:
        console.print(f"[red]ERROR[/] dd exited with {proc.returncode}")
        sys.exit(proc.returncode)


def main():
    parser = argparse.ArgumentParser(
        prog="dd_rich.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__
    )
    parser.add_argument(
        "-b", "--bs",
        type=parse_numeric,
        default=parse_numeric("1M"),
        help="Block size (arithmetic, M/G suffix)"
    )
    parser.add_argument(
        "-c", "--count",
        type=parse_numeric,
        help="Number of blocks to copy (units of BS)"
    )
    parser.add_argument("INPUT", help="Source file or block device")
    parser.add_argument("TARGET", nargs='+', help="Destination file(s) or device(s)")
    parser.add_argument("-h", "--help", action="help", help="Show help and exit")
    args = parser.parse_args()

    if os.geteuid() != 0:
        console.print("[red]ERROR[/] Must be run as root.")
        sys.exit(1)

    for dest in args.TARGET:
        run_dd(args.INPUT, dest, args.bs, args.count)

    console.print("[green]All operations completed successfully.[/]")

if __name__ == '__main__':
    main()

