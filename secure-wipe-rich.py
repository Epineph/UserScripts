#!/usr/bin/env python3
import os
import re
import argparse
import subprocess
import sys
from ast import literal_eval, parse, Expression
from rich.progress import Progress, BarColumn, TransferSpeedColumn, TimeElapsedColumn, TimeRemainingColumn, TextColumn
from rich.console import Console

console = Console()

def parse_passes(value: str) -> int:
    """Allow simple arithmetic for pass count."""
    try:
        node = parse(value, mode='eval')
        # ensure only numeric operations...
        number = literal_eval(node)
    except Exception:
        raise argparse.ArgumentTypeError(f"Invalid passes '{value}'")
    if not isinstance(number, int) or number < 1:
        raise argparse.ArgumentTypeError("Passes must be positive integer")
    return number


def parse_size(value: str) -> int:
    m = re.fullmatch(r"\s*([0-9+\-*/() ]+)([MmGg])?[iI]?[Bb]?\s*", value)
    if not m:
        raise argparse.ArgumentTypeError(f"Invalid size '{value}'")
    expr, unit = m.group(1), m.group(2)
    try:
        node = parse(expr, mode='eval')
        number = literal_eval(node)
    except Exception:
        raise argparse.ArgumentTypeError(f"Invalid arithmetic in size '{expr}'")
    if unit:
        if unit.lower() == 'm':
            number *= 1024**2
        else:
            number *= 1024**3
    return number


def get_size(path: str) -> int:
    try:
        import fcntl, struct
        BLKGETSIZE64 = 0x80081272
        with open(path, 'rb') as f:
            buf = fcntl.ioctl(f, BLKGETSIZE64, b' ' * 8)
            return struct.unpack('Q', buf)[0]
    except Exception:
        return os.path.getsize(path)


def wipe_one(path: str, source: str, bs: int, passes: int):
    size = get_size(path)
    for p in range(1, passes+1):
        desc = f"Wiping {os.path.basename(path)} pass {p}/{passes}"
        cmd = ["dd", f"if={source}", f"of={path}", f"bs={bs}", "status=progress"]
        proc = subprocess.Popen(cmd, stderr=subprocess.PIPE, text=True)
        progress = Progress(
            TextColumn("[bold blue]" + desc), BarColumn(), TransferSpeedColumn(),
            TimeElapsedColumn(), TimeRemainingColumn(), console=console, transient=True
        )
        task = progress.add_task("", total=size)
        with progress:
            for line in proc.stderr:
                m = re.match(r"^(\d+)", line)
                if m:
                    progress.update(task, completed=int(m.group(1)))
            proc.wait()
        if proc.returncode != 0:
            console.print(f"[red]ERROR[/] pass {p} failed (code {proc.returncode})")
            break


def main_wipe():
    parser = argparse.ArgumentParser(prog="secure_wipe.py", description="Rich secure-wipe utility")
    group = parser.add_mutually_exclusive_group()
    group.add_argument('-z','--zero', action='store_true', help='Use /dev/zero')
    group.add_argument('-r','--random', action='store_true', help='Use /dev/urandom')
    parser.add_argument('-p','--passes', type=parse_passes, default=1,
                        help='Number of overwrite passes, arithmetic OK')
    parser.add_argument('-b','--bs', type=parse_size, default=parse_size('1M'),
                        help='Block size (arithmetic & suffix OK)')
    parser.add_argument('targets', nargs='+', help='Devices or files to erase')
    args = parser.parse_args()

    if os.geteuid() != 0:
        console.print("[red]ERROR[/] Must run as root.")
        sys.exit(1)
    source = '/dev/urandom' if args.random else '/dev/zero'
    for tgt in args.targets:
        if not os.path.exists(tgt):
            console.print(f"[red]ERROR[/] {tgt} not found.")
            continue
        wipe_one(tgt, source, args.bs, args.passes)
    console.print("[green]Secure wipe completed.[/]")

if __name__ == '__main__':
    # Detect invocation
    prog = os.path.basename(sys.argv[0])
    if 'dd_rich' in prog:
        main_dd()
    else:
        main_wipe()
