#!/usr/bin/env python3
"""
sort_pkg_by_size_v3.py – List installed Arch packages by on-disk size, with
an enumerated, rich table output and optional selective removal.

Usage:
  # List all packages, sorted descending by size:
  ./sort_pkg_by_size_v3.py

  # Show only the top-10 largest packages:
  ./sort_pkg_by_size_v3.py -n 10

  # After listing, prompt to select and remove packages by index/range:
  ./sort_pkg_by_size_v3.py -n 10 --delete
"""

import argparse
import re
import subprocess
import sys
from typing import List, Tuple, Set

from rich.console import Console
from rich.table import Table

# ---------------------------------------------------------------------------#
# 1. Constants and Regex                                                     #
# ---------------------------------------------------------------------------#
_SIZE_RE = re.compile(r"Installed Size\s*:\s*([\d\.,]+)\s*(KiB|MiB|GiB)")

# ---------------------------------------------------------------------------#
# 2. Pacman Data Gathering                                                   #
# ---------------------------------------------------------------------------#

def get_pacman_info() -> str:
    """
    Run `pacman -Qi` and return its stdout. Exit on error.
    """
    try:
        proc = subprocess.run(
            ["pacman", "-Qi"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True,
        )
        return proc.stdout
    except subprocess.CalledProcessError as e:
        print(f"Error: failed to run `pacman -Qi`:\n{e.stderr}", file=sys.stderr)
        sys.exit(1)

# ---------------------------------------------------------------------------#
# 3. Parsing Logic                                                           #
# ---------------------------------------------------------------------------#

def parse_info_block(block: str) -> Tuple[str, float]:
    """
    From one `pacman -Qi` block, extract:
      – name (str)
      – size in KiB (float)

    Falls back to "<unknown>" or 0.0 if parsing fails.
    """
    name = "<unknown>"
    size_kib = 0.0

    for line in block.splitlines():
        if line.startswith("Name"):
            _, val = line.split(":", 1)
            name = val.strip() or name

        elif line.startswith("Installed Size"):
            m = _SIZE_RE.search(line)
            if m:
                num_str, unit = m.groups()
                num = float(num_str.replace(",", "."))
                if unit == "KiB":
                    size_kib = num
                elif unit == "MiB":
                    size_kib = num * 1024
                elif unit == "GiB":
                    size_kib = num * 1024 * 1024

    return name, size_kib

# ---------------------------------------------------------------------------#
# 4. Human-readable Formatter                                                 #
# ---------------------------------------------------------------------------#

def human_readable(kib: float) -> str:
    """
    Convert KiB → MiB or GiB with 2 decimals:
      • < 1 GiB → MiB
      • ≥ 1 GiB → GiB
    """
    mib = kib / 1024
    if mib < 1024:
        return f"{mib:.2f} MiB"
    else:
        return f"{(mib/1024):.2f} GiB"

# ---------------------------------------------------------------------------#
# 5. Build & Sort Package List                                               #
# ---------------------------------------------------------------------------#

def build_package_list(limit: int = None) -> List[Tuple[str, float]]:
    """
    Return a list of (name, size_kib), sorted descending by size.
    If `limit` is given, truncate to the top-N packages.
    """
    raw = get_pacman_info()
    blocks = raw.strip().split("\n\n")
    pkgs = [parse_info_block(b) for b in blocks]
    pkgs.sort(key=lambda x: x[1], reverse=True)
    return pkgs if limit is None else pkgs[:limit]

# ---------------------------------------------------------------------------#
# 6. Table Output                                                             #
# ---------------------------------------------------------------------------#

def print_table(rows: List[Tuple[str, float]], console: Console) -> None:
    """
    Render a Rich table of (index, package, size) to the given console.
    """
    table = Table(show_header=True, header_style="bold cyan")
    table.add_column("#", style="dim", justify="right")
    table.add_column("Package", style="dim", no_wrap=True)
    table.add_column("Installed Size", justify="right")

    for idx, (name, size_kib) in enumerate(rows, start=1):
        size_text = human_readable(size_kib) if size_kib > 0 else "N/A"
        table.add_row(str(idx), name, size_text)

    console.print(table)

# ---------------------------------------------------------------------------#
# 7. Parse User Selection                                                     #
# ---------------------------------------------------------------------------#

def parse_selection(selection: str, max_index: int) -> Set[int]:
    """
    Convert a string like "1 3-5 7" into a set of integers {1,3,4,5,7}.
    Raises ValueError on invalid tokens or out-of-range indices.
    """
    chosen: Set[int] = set()
    tokens = selection.split()

    for token in tokens:
        if '-' in token:
            start_str, end_str = token.split('-', 1)
            start = int(start_str)
            end = int(end_str)
            if start < 1 or end < start or end > max_index:
                raise ValueError(f"Invalid range: {token}")
            chosen.update(range(start, end + 1))
        else:
            num = int(token)
            if num < 1 or num > max_index:
                raise ValueError(f"Invalid index: {token}")
            chosen.add(num)

    return chosen

# ---------------------------------------------------------------------------#
# 8. Main Logic & Deletion                                                    #
# ---------------------------------------------------------------------------#

def main() -> None:
    parser = argparse.ArgumentParser(
        description="List installed packages sorted by size, with optional selective removal."
    )
    parser.add_argument(
        "-n", "--limit", type=int, metavar="N",
        help="show only the N largest packages (default: all)"
    )
    parser.add_argument(
        "-d", "--delete", action="store_true",
        help="after listing, prompt to select and delete packages by index"
    )
    args = parser.parse_args()

    console = Console()
    rows = build_package_list(limit=args.limit)
    if not rows:
        console.print("No packages found.", style="bold yellow")
        sys.exit(0)

    print_table(rows, console)

    if args.delete:
        max_idx = len(rows)
        console.print(
            f"\nEnter package numbers or ranges to remove (1–{max_idx}), e.g. '1 3-5':",
            style="bold red"
        )
        selection = input("Selection: ").strip()

        try:
            chosen = parse_selection(selection, max_idx)
        except (ValueError, TypeError) as e:
            console.print(f"Error parsing selection: {e}", style="bold red")
            sys.exit(1)

        # Map indices to package names
        pkg_names = [rows[i - 1][0] for i in sorted(chosen)]

        if not pkg_names:
            console.print("No valid packages selected.", style="bold yellow")
            sys.exit(0)

        console.print(
            f"\nSelected {len(pkg_names)} packages for removal:", style="bold red"
        )
        for name in pkg_names:
            console.print(f"  • {name}")

        confirm = input("Proceed with removal? [y/N] ").strip().lower()
        if confirm not in ('y', 'yes'):
            console.print("Aborted. No packages were removed.", style="bold yellow")
            sys.exit(0)

        # Execute removal
        try:
            subprocess.run(
                ["sudo", "pacman", "-Rns", *pkg_names],
                check=True
            )
            console.print("\nPackages successfully removed.", style="bold green")
        except subprocess.CalledProcessError as e:
            console.print(f"Error removing packages:\n{e}", style="bold red")
            sys.exit(1)

if __name__ == "__main__":
    main()

