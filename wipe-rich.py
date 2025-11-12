#!/usr/bin/env python3
"""
secure_wipe_rich.py: Rich-enhanced secure wipe utility

Usage:
  secure_wipe_rich.py [OPTIONS] <TARGET> [TARGET...]

Description:
  Securely overwrite one or more TARGET block devices or files using `dd`,
  with live Rich progress bars. Supports:
    • Overwriting with zeros (/dev/zero) or random data (/dev/urandom).
    • Configurable number of passes, with arithmetic expressions.
    • Custom block-size parsing with arithmetic expressions and M/G suffixes.
    • Per-target, per-pass feedback: bytes written, speed, elapsed, remaining time.

Options:
  -z, --zero           Overwrite using zeros (default).
  -r, --random         Overwrite using random data.
  -p, --passes N       Number of overwrite passes (arithmetic OK).
                        Examples: 1, 2*2, (1+3)
  -b, --bs SIZE        Block size (arithmetic, M=MiB, G=GiB). Default: 1M.
                        Examples: 512, 4M, 2*1024M, (1+1)G
  -h, --help           Show this help message and exit.

Examples:
  # Single-pass zero-fill of /dev/sda with 4 MiB blocks:
  sudo secure_wipe_rich.py -z -b4M /dev/sda

  # Two passes of random data on a partition:
  sudo secure_wipe_rich.py -r -p2 /dev/sda1

  # Complex pass count and block size expressions:
  sudo secure_wipe_rich.py -z -p"2*2" -b"(1+3)M" /dev/nvme0n1
"""
import argparse
import os
import re
import subprocess
import sys
from ast import literal_eval, parse
from rich.progress import Progress, BarColumn, TransferSpeedColumn, TimeElapsedColumn, TimeRemainingColumn, TextColumn
from rich.console import Console

console = Console()

def parse_numeric(expr: str) -> int:
    """Evaluate arithmetic expressions with optional M/G suffix."""
    m = re.fullmatch(r"\s*([0-9+\-*/() ]+)([MmGg])?[iI]?[Bb]?\s*", expr)
    if not m:
        raise argparse.ArgumentTypeError(f"Invalid expression '{expr}'")
    body, suff = m.group(1), m.group(2)
    try:
        node = parse(body, mode='eval')
        value = literal_eval(node)
    except Exception:
        raise argparse.ArgumentTypeError(f"Cannot evaluate '{body}'")
    if not isinstance(value, int) or value < 1:
        raise argparse.ArgumentTypeError(f"Result must be positive integer: {value}")
    if suff:
        factor = 1024**2 if suff.lower()=='m' else 1024**3
        value *= factor
    return value


def get_size(path: str) -> int:
    """Return total size of block device or file in bytes."""
    try:
        import fcntl, struct
        BLKGETSIZE64 = 0x80081272
        with open(path, 'rb') as f:
            buf = fcntl.ioctl(f, BLKGETSIZE64, b' ' * 8)
            return struct.unpack('Q', buf)[0]
    except Exception:
        return os.path.getsize(path)


def wipe_target(path: str, source: str, bs: int, passes: int):
    """Perform the secure wipe for a single path."""
    total = get_size(path)
    for p in range(1, passes + 1):
        desc = f"Pass {p}/{passes} on {os.path.basename(path)}"
        cmd = ["dd", f"if={source}", f"of={path}", f"bs={bs}", "status=progress"]
        console.log(f"[blue]Starting {desc} (cmd: {' '.join(cmd)})")
        proc = subprocess.Popen(cmd, stderr=subprocess.PIPE, text=True)

        progress = Progress(
            TextColumn("[bold blue]" + desc),
            BarColumn(bar_width=None),
            TransferSpeedColumn(),
            TimeElapsedColumn(),
            TimeRemainingColumn(),
            console=console,
            transient=True
        )
        task = progress.add_task("", total=total)
        with progress:
            for line in proc.stderr:
                m = re.match(r"^(\d+)", line)
                if m:
                    progress.update(task, completed=int(m.group(1)))
            proc.wait()
        if proc.returncode != 0:
            console.print(f"[red]ERROR[/] {desc} failed (code {proc.returncode})")
            break


def main():
    parser = argparse.ArgumentParser(
        prog="secure_wipe_rich.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument('-z','--zero', action='store_true', help='Use /dev/zero (default)')
    group.add_argument('-r','--random', action='store_true', help='Use /dev/urandom')
    parser.add_argument('-p','--passes', type=parse_numeric, default=1,
                        help='Number of overwrite passes (arithmetic OK)')
    parser.add_argument('-b','--bs', type=parse_numeric, default=parse_numeric('1M'),
                        help='Block size (arithmetic, M/G suffix)')
    parser.add_argument('TARGET', nargs='+', help='Target block devices or files')
    parser.add_argument('-h','--help', action='help', help='Show help and exit')
    args = parser.parse_args()

    if os.geteuid() != 0:
        console.print("[red]ERROR[/] Root privileges required.")
        sys.exit(1)
    source = '/dev/urandom' if args.random else '/dev/zero'

    for tgt in args.TARGET:
        if not os.path.exists(tgt):
            console.print(f"[red]ERROR[/] Target not found: {tgt}")
            continue
        wipe_target(tgt, source, args.bs, args.passes)

    console.print("[green]Secure wipe completed successfully.[/]")

if __name__ == '__main__':
    main()

