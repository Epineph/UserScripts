#!/usr/bin/env python3
"""
Script: sort_installed_package_sizes.py

Purpose
-------
Display installed Arch-Linux packages sorted by descending on-disk size.

Key features added in this revision
-----------------------------------
1. Output is always expressed in MiB or GiB:
       < 1024 MiB  →  MiB
     ≥ 1024 MiB  →  GiB
2. Optional CLI argument ``--limit / -n`` to show only the *N* largest entries.

Usage examples
--------------
# Show *all* packages (MiB/GiB units only)
$ ./sort_installed_package_sizes.py

# Show the ten largest packages
$ ./sort_installed_package_sizes.py -n 10

Minimum requirements
--------------------
* Python ≥ 3.6
* pacman in $PATH            (script calls ``pacman -Qi``)
"""

import argparse
import re
import subprocess
import sys
from typing import List, Tuple

# ---------------------------------------------------------------------------#
# 1. Sub-process helper                                                       #
# ---------------------------------------------------------------------------#
def get_pacman_info() -> str:
    """
    Run ``pacman -Qi`` and capture its full stdout.

    Exits the script with code 1 if pacman returns a non-zero status.
    """
    try:
        proc = subprocess.run(
            ["pacman", "-Qi"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True,
        )
    except subprocess.CalledProcessError as e:
        print(f"Error: failed to execute 'pacman -Qi':\n{e.stderr}", file=sys.stderr)
        sys.exit(1)
    return proc.stdout


# ---------------------------------------------------------------------------#
# 2. Parsing                                                                  #
# ---------------------------------------------------------------------------#
_SIZE_RE = re.compile(r"Installed Size\s*:\s*([\d\.,]+)\s*(KiB|MiB|GiB)")

def parse_info_block(block: str) -> Tuple[str, float]:
    """
    Extract package *name* and *size* (in KiB) from one ``pacman -Qi`` block.

    Returns
    -------
    (name, size_kib)
        *name*      → str  (never None; fall back to "<unknown>" if absent)
        *size_kib*  → float  (0.0 if size missing/unparsable)
    """
    name = "<unknown>"
    size_kib = 0.0

    for line in block.splitlines():
        if line.startswith("Name"):
            parts = line.split(":", 1)
            name = parts[1].strip() if len(parts) == 2 else name

        elif line.startswith("Installed Size"):
            m = _SIZE_RE.search(line)
            if m:
                num_str, unit = m.groups()
                num = float(num_str.replace(",", "."))  # localised decimals
                if unit == "KiB":
                    size_kib = num
                elif unit == "MiB":
                    size_kib = num * 1024
                elif unit == "GiB":
                    size_kib = num * 1024 * 1024

    return name, size_kib


# ---------------------------------------------------------------------------#
# 3. Formatting helper                                                       #
# ---------------------------------------------------------------------------#
def human_readable(kib: float) -> str:
    """
    Convert KiB to a string in MiB **or** GiB, always with two decimals.

    Policy
    ------
    •  < 1 GiB → MiB
    • ≥ 1 GiB → GiB
    """
    mib = kib / 1024
    if mib < 1024:                   # < 1 GiB
        return f"{mib:.2f} MiB"
    else:                            # ≥ 1 GiB
        gib = mib / 1024
        return f"{gib:.2f} GiB"


# ---------------------------------------------------------------------------#
# 4. Main logic                                                              #
# ---------------------------------------------------------------------------#
def build_table(limit: int | None = None) -> List[Tuple[str, float]]:
    """
    Collect and sort package data, returning a list of (name, size_kib).

    Parameters
    ----------
    limit : int | None
        If given, truncate the list to *limit* largest packages.
    """
    raw = get_pacman_info()
    blocks = raw.strip().split("\n\n")

    pkgs = [parse_info_block(b) for b in blocks]
    pkgs.sort(key=lambda x: x[1], reverse=True)  # largest first

    if limit is not None:
        pkgs = pkgs[:limit]

    return pkgs


def print_table(rows: List[Tuple[str, float]]) -> None:
    """
    Pretty-print the package table to stdout.
    """
    header_pkg = "Package"
    header_size = "Installed Size"
    print(f"{header_pkg:<33} {header_size:>12}")
    print("-" * 47)
    for name, size_kib in rows:
        size_text = human_readable(size_kib) if size_kib > 0 else "N/A"
        print(f"{name:<33} {size_text:>12}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="List installed packages sorted by size (MiB/GiB)."
    )
    parser.add_argument(
        "-n",
        "--limit",
        type=int,
        metavar="N",
        help="show only the N largest packages (default: all)",
    )
    args = parser.parse_args()

    table = build_table(limit=args.limit)
    print_table(table)


# ---------------------------------------------------------------------------#
if __name__ == "__main__":                                               # noqa: D401
    main()

