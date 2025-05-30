#!/usr/bin/env python3
"""
py_multi_copy.py: Pure-Python multi-target copier with unified Rich progress and ETA

Reads from an input (file or block device) in configurable block sizes,
writes to one or more outputs in parallel, and displays a single progress bar
with bytes transferred, speed, elapsed and remaining time.

Usage:
  sudo py_multi_copy.py [OPTIONS] -i INPUT -t TARGET [ -t TARGET ... ]

Options:
  -i, --input     Input file or device
  -t, --target    Output file(s); can repeat to fan out
  -b, --bs        Block size (e.g. 512, 4K, 1M, 2MiB) [default: 1MiB]
  -c, --count     Number of blocks to copy (overrides reading until EOF)
  -h, --help      Show this help and exit

Requirements:
  • Python 3.8+
  • rich (`pip install rich`)

Logic:
 1. Parse sizes with suffixes (K/M/G) → bytes
 2. Determine total bytes = count × bs, or file size of input
 3. Set up a Rich Progress with a single task of total_bytes
 4. Loop: read chunks from input, write to each output, update progress

"""
import argparse
import os
import re
import sys
from rich.progress import (
    Progress, TextColumn, BarColumn,
    TransferSpeedColumn, TimeElapsedColumn, TimeRemainingColumn
)
from rich.console import Console

console = Console()

def parse_size(s: str) -> int:
    """Parse integer with optional K/M/G suffix."""
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


def main():
    parser = argparse.ArgumentParser(
        prog="py_multi_copy.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__
    )
    parser.add_argument('-i', '--input', required=True, help="Input path")
    parser.add_argument('-t', '--target', required=True, action='append',
                        help="Output paths (repeat to fan out)")
    parser.add_argument('-b', '--bs', type=parse_size, default=parse_size('1M'),
                        help="Block size [default: 1MiB]")
    parser.add_argument('-c', '--count', type=int,
                        help="Number of blocks to copy")
    args = parser.parse_args()

    # Open input
    try:
        infile = open(args.input, 'rb')
    except Exception as e:
        console.print(f"[red]ERROR[/] cannot open input: {e}")
        sys.exit(1)

    # Open outputs
    outs = []
    for t in args.target:
        try:
            f = open(t, 'wb')
            outs.append(f)
        except Exception as e:
            console.print(f"[red]ERROR[/] cannot open output {t}: {e}")
            sys.exit(1)

    # Compute total bytes
    if args.count:
        total = args.count * args.bs
        blocks = args.count
    else:
        # try to get size
        try:
            st = os.stat(args.input)
            total = st.st_size
            blocks = (total + args.bs - 1) // args.bs
        except Exception:
            total = None
            blocks = None

    # Setup progress
    columns = [
        TextColumn("[bold blue]Copying"),
        BarColumn(bar_width=None),
    ]
    if total:
        columns.append(TextColumn("{task.percentage:>3.0f}%"))
    columns += [
        TransferSpeedColumn(),
        TimeElapsedColumn(),
        TimeRemainingColumn()
    ]
    progress = Progress(*columns, console=console, transient=True)
    task = progress.add_task("copy", total=total)

    # Perform copy
    with progress:
        for _ in range(blocks or sys.maxsize):
            chunk = infile.read(args.bs)
            if not chunk:
                break
            for f in outs:
                f.write(chunk)
            progress.update(task, advance=len(chunk))

    # Cleanup
    infile.close()
    for f in outs:
        f.close()
    console.print("[green]Copy complete.[/]")

if __name__ == '__main__':
    main()
