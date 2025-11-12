#!/usr/bin/env python3
"""
sort_pkg_by_size.py – List installed Arch packages by on-disk size, with
a rich table output and optional removal.

Usage:
  # Just list all packages, sorted descending by size:
  ./sort_pkg_by_size.py

  # Show only the top-10 largest packages:
  ./sort_pkg_by_size.py -n 10

  # After listing, prompt to remove those same packages:
  ./sort_pkg_by_size.py -n 10 --delete
"""

import argparse
import re
import subprocess
import sys
from typing import List, Tuple

from rich.console import Console
from rich.table import Table

# ──────────────────────────────────────────────────────────────────────────────

_SIZE_RE = re.compile(r"Installed Size\s*:\s*([\d\.,]+)\s*(KiB|MiB|GiB)")

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

def print_table(rows: List[Tuple[str, float]], console: Console) -> None:
    """
    Render a Rich table of (package, size) to the given console.
    """
    table = Table(show_header=True, header_style="bold cyan")
    table.add_column("Package", style="dim", no_wrap=True)
    table.add_column("Installed Size", justify="right")

    for name, size_kib in rows:
        size_text = human_readable(size_kib) if size_kib > 0 else "N/A"
        table.add_row(name, size_text)

    console.print(table)

def main() -> None:
    parser = argparse.ArgumentParser(
        description="List installed packages sorted by size (MiB/GiB)."
    )
    parser.add_argument(
        "-n", "--limit", type=int, metavar="N",
        help="show only the N largest packages (default: all)"
    )
    parser.add_argument(
        "-d", "--delete", action="store_true",
        help="after listing, prompt to delete these packages"
    )
    args = parser.parse_args()

    console = Console()
    rows = build_package_list(limit=args.limit)
    print_table(rows, console)

    # If --delete was passed, confirm and then remove
    if args.delete:
        pkg_names = [name for name, _ in rows]
        if not pkg_names:
            console.print("\nNo packages to delete.", style="bold yellow")
            sys.exit(0)

        console.print("\n[bold red]Warning:[/] This will remove the above packages via pacman.")
        confirm = input("Proceed with removal? [y/N] ").strip().lower()
        if confirm in ("y", "yes"):
            try:
                subprocess.run(
                    ["sudo", "pacman", "-Rns", *pkg_names],
                    check=True
                )
                console.print("\nPackages successfully removed.", style="bold green")
            except subprocess.CalledProcessError as e:
                console.print(f"\nError removing packages:\n{e}", style="bold red")
                sys.exit(1)
        else:
            console.print("\nAborted. No packages were removed.", style="bold yellow")

if __name__ == "__main__":
    main()

