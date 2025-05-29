#!/usr/bin/env python3
"""
dd_rich_enhanced.py: Rich-enhanced wrapper for `dd` with extended unit flags and multi input-target pairing

Usage:
  dd_rich_enhanced.py [OPTIONS] [<INPUT> <TARGET> [<TARGET>...]]

Description:
  Copy raw data from INPUT(s) to TARGET(s) using `dd`, showing a live Rich progress bar.
  Supports:
    • Traditional -b/--bs SIZE and -c/--count COUNT with suffixes KiB/Ki/MiB/M/GiB/G
    • Contextual unit flags: -k/--kilobytes, -m/--megabytes, -g/--gigabytes, following -b or -c to compose sizes
    • Inline suffix expressions: -c 4096KiB, -c 2GiB, etc.
    • Multiple -i/--input / -t/--target pairs: e.g. -i /dev/zero -t out1.img -t out2.img -i src2 -t dst2

Options:
  -b, --bs [SIZE]        Block size: explicit SIZE or compose via -k/-m/-g. Default: 1MiB
  -c, --count [COUNT]    Number of bytes or blocks to copy: explicit COUNT or compose via -k/-m/-g
  -k, --kilobytes N      Add N × 1024 bytes to current context (bs or count)
  -m, --megabytes N      Add N × 1024² bytes to current context (bs or count)
  -g, --gigabytes N      Add N × 1024³ bytes to current context (bs or count)
  -i, --input INPUT      Specify source (can repeat with paired -t)
  -t, --target TARGET    Specify destination(s) for last -i (can repeat)
  -h, --help             Show help and exit

Examples:
  # Copy entire /dev/sda with 4MiB blocks:
  sudo dd_rich_enhanced.py -b 4M /dev/sda backup1.img backup2.img

  # Copy first 2GiB of /dev/zero with default block size:
  sudo dd_rich_enhanced.py -c 2GiB /dev/zero zeros.img

  # Copy using contextual flags:
  sudo dd_rich_enhanced.py -b -m 4 -k 512 -c -g 2 /dev/sdb image.img

  # Multiple input-target pairs:
  sudo dd_rich_enhanced.py -i /dev/zero -t out1.img -t out2.img -i /dev/urandom -t rand.bin

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

# --- Helper functions ---
def parse_size(expr: str) -> int:
    """
    Parse an arithmetic expression with optional K/M/G suffix into bytes.
    Supports suffixes: K, KiB, KB; M, MiB, MB; G, GiB, GB (case-insensitive).
    """
    # Regex: capture numeric expression and optional suffix
    m = re.fullmatch(r"\s*([0-9+\-*/() ]+)([KkMmGg])([iI]?[bB]{0,2})?\s*", expr)
    if not m:
        raise argparse.ArgumentTypeError(f"Invalid size expression '{expr}'")
    body, prefix, _ = m.groups()
    try:
        node = parse(body, mode='eval')
        value = literal_eval(node)
    except Exception:
        raise argparse.ArgumentTypeError(f"Cannot evaluate '{body}'")
    if not isinstance(value, int) or value < 0:
        raise argparse.ArgumentTypeError(f"Result not non-negative integer: {value}")
    # Determine multiplier
    unit = prefix.lower()
    if unit == 'k':
        factor = 1024
    elif unit == 'm':
        factor = 1024**2
    elif unit == 'g':
        factor = 1024**3
    else:
        factor = 1
    return value * factor

# Custom argparse actions to track context
class ContextAction(argparse.Action):
    """Base for -b and -c to set context and initial values."""
    def __call__(self, parser, namespace, values, option_string=None):
        # Set last context
        namespace._last_ctx = self.dest
        # Mark that this option was used
        setattr(namespace, f"_{self.dest}_used", True)
        # Initialize byte accumulator if first use
        if getattr(namespace, f"{self.dest}_bytes", None) is None:
            setattr(namespace, f"{self.dest}_bytes", 0)
        # If an argument value was provided, parse it directly
        if values is not None:
            # For count: handle suffix -> bytes; for bs: always bytes
            if self.dest == 'count':
                # If suffix in expr, parse bytes and store, else treat as blocks
                if re.search(r"[KkMmGg]", values):
                    setattr(namespace, 'count_bytes', parse_size(values))
                else:
                    # plain integer blocks
                    try:
                        blocks = literal_eval(parse(values, mode='eval'))
                    except Exception:
                        raise argparse.ArgumentTypeError(f"Cannot evaluate count '{values}'")
                    if not isinstance(blocks, int) or blocks < 0:
                        raise argparse.ArgumentTypeError(f"Count not non-negative integer: {blocks}")
                    setattr(namespace, 'count_blocks', blocks)
            else:  # bs context
                setattr(namespace, 'bs_bytes', parse_size(values))

class UnitAction(argparse.Action):
    """Handles -k, -m, -g by adding to the last context in bytes."""
    MULTIPLIERS = {'k': 1024, 'm': 1024**2, 'g': 1024**3}
    def __call__(self, parser, namespace, values, option_string=None):
        val = int(values)
        ctx = getattr(namespace, '_last_ctx', None)
        if ctx not in ('bs', 'count'):
            parser.error(f"{option_string} must follow -b/--bs or -c/--count")
        # Lazy initialize byte accumulator
        if getattr(namespace, f"{ctx}_bytes", None) is None:
            setattr(namespace, f"{ctx}_bytes", 0)
        # Add bytes
        mul = self.MULTIPLIERS[self.dest[0]]
        setattr(namespace, f"{ctx}_bytes", getattr(namespace, f"{ctx}_bytes") + val * mul)
        # Mark used
        setattr(namespace, f"_{ctx}_used", True)
        # Clear any block-based count if count context
        if ctx == 'count':
            namespace.count_blocks = None

class InputAction(argparse.Action):
    """Collects -i/--input and pairs with subsequent -t/--target"""
    def __call__(self, parser, namespace, values, option_string=None):
        namespace._last_ctx = 'input'
        # Ensure pairs list exists
        if namespace._pairs is None:
            namespace._pairs = []
        # Start new pair
        namespace._pairs.append({'input': values, 'targets': []})

class TargetAction(argparse.Action):
    """Adds targets to the most recent input pair"""
    def __call__(self, parser, namespace, values, option_string=None):
        if namespace._last_ctx != 'input' or not namespace._pairs:
            parser.error("-t/--target must follow -i/--input")
        # Append to last pair
        namespace._pairs[-1]['targets'].append(values)
        namespace._last_ctx = 'target'

# --- Core dd execution ---
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

# --- Entry point ---
def main():
    # Initialize parser
    parser = argparse.ArgumentParser(
        prog="dd_rich_enhanced.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__
    )
    # Context and unit flags
    parser.add_argument('-b', '--bs', nargs='?', action=ContextAction, dest='bs', metavar='SIZE',
                        help='Block size: explicit SIZE or use -k/-m/-g to compose')
    parser.add_argument('-c', '--count', nargs='?', action=ContextAction, dest='count', metavar='COUNT',
                        help='Number of bytes or blocks to copy')
    parser.add_argument('-k', '--kilobytes', action=UnitAction, metavar='N',
                        help='Add N × 1024 bytes to preceding -b/-c context')
    parser.add_argument('-m', '--megabytes', action=UnitAction, metavar='N',
                        help='Add N × 1024² bytes to preceding -b/-c context')
    parser.add_argument('-g', '--gigabytes', action=UnitAction, metavar='N',
                        help='Add N × 1024³ bytes to preceding -b/-c context')
    # Input-target pairing
    parser.add_argument('-i', '--input', action=InputAction, metavar='INPUT',
                        help='Source file/device (pair with -t)')
    parser.add_argument('-t', '--target', action=TargetAction, metavar='TARGET',
                        help='Destination file/device (for last -i)')
    # Positional fallback
    parser.add_argument('positional', nargs='*', help='[INPUT TARGET [TARGET...]] (if no -i/-t used)')
    args = parser.parse_args()

    # Ensure running as root
    if os.geteuid() != 0:
        console.print("[red]ERROR[/] Must be run as root.")
        sys.exit(1)

    # Determine block size in bytes (default 1MiB)
    bs = getattr(args, 'bs_bytes', None)
    if bs is None:
        bs = 1024**2
    # Determine count in blocks
    if getattr(args, '_count_used', False):
        # if byte-count specified
        cb = getattr(args, 'count_bytes', None)
        if cb is not None:
            if cb % bs != 0:
                console.print(f"[red]ERROR[/] count bytes {cb} not divisible by bs {bs}")
                sys.exit(1)
            count = cb // bs
        else:
            count = getattr(args, 'count_blocks', None)
    else:
        count = None

    # Build input-target list
    pairs = getattr(args, '_pairs', None)
    if pairs:
        # Use -i/-t pairs
        for p in pairs:
            if not p['targets']:
                console.print(f"[red]ERROR[/] No targets specified for input {p['input']}")
                sys.exit(1)
            for tgt in p['targets']:
                run_dd(p['input'], tgt, bs, count)
    else:
        # Fallback to positional args
        pos = args.positional
        if len(pos) < 2:
            parser.error("Must specify at least an input and one target")
        src = pos[0]
        for dst in pos[1:]:
            run_dd(src, dst, bs, count)

    console.print("[green]All operations completed successfully.[/")

if __name__ == '__main__':
    main()

