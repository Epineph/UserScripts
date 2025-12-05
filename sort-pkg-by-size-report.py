#!/usr/bin/env python3
"""
Script: sort_pkg_by_size

Purpose
-------
Display installed Arch-Linux packages sorted by descending on-disk size.

Key features
------------
1. Output is always expressed in MiB or GiB:
       < 1024 MiB  →  MiB
     ≥ 1024 MiB  →  GiB
2. Optional CLI argument ``--limit / -n`` to show only the *N* largest entries.
3. Optional Rich-based pretty printing.
4. Optional CSV export of the current table.

Usage examples
--------------
# Show *all* packages (MiB/GiB units only)
$ sort_pkg_by_size

# Show the ten largest packages with Rich table formatting
$ sort_pkg_by_size -n 10

# Export the full table to CSV and print the destination
$ sort_pkg_by_size --csv --verbose
"""

import argparse
import csv
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import List, Tuple

# Rich is optional; we fall back to plain text if unavailable.
try:
    from rich.console import Console
    from rich.table import Table

    _RICH_AVAILABLE = True
except Exception:  # pragma: no cover - optional dependency
    Console = None  # type: ignore[assignment]
    Table = None  # type: ignore[assignment]
    _RICH_AVAILABLE = False


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
        print(
            f"Error: failed to execute 'pacman -Qi':\n{e.stderr}",
            file=sys.stderr,
        )
        sys.exit(1)
    return proc.stdout


# ---------------------------------------------------------------------------#
# 2. Parsing                                                                  #
# ---------------------------------------------------------------------------#
_SIZE_RE = re.compile(r"Installed Size\s*:\s*([\d\.,]+)\s*(KiB|MiB|GiB)")


def parse_info_block(block: str) -> Tuple[str, float]:
    """
    Extract package *name* and *size* (in KiB) from one ``pacman -Qi`` block.
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
    """
    mib = kib / 1024
    if mib < 1024:  # < 1 GiB
        return f"{mib:.2f} MiB"
    gib = mib / 1024
    return f"{gib:.2f} GiB"


def default_csv_path() -> Path:
    """
    Build a per-run CSV output path under $HOME/exported_csv_logs.

    Example:
      $HOME/exported_csv_logs/sort_pkg_by_size/20251205_210101/pkg_by_size_report.csv
    """
    base = (
        Path.home()
        / "exported_csv_logs"
        / "sort_pkg_by_size"
        / datetime.now().strftime("%Y%m%d_%H%M%S")
    )
    base.mkdir(parents=True, exist_ok=True)
    return base / "pkg_by_size_report.csv"


# ---------------------------------------------------------------------------#
# 4. Main logic                                                              #
# ---------------------------------------------------------------------------#
def build_table(limit: int | None = None) -> List[Tuple[str, float]]:
    """
    Collect and sort package data, returning a list of (name, size_kib).
    """
    raw = get_pacman_info()
    blocks = raw.strip().split("\n\n")

    pkgs = [parse_info_block(b) for b in blocks if b.strip()]
    pkgs.sort(key=lambda x: x[1], reverse=True)  # largest first

    if limit is not None:
        pkgs = pkgs[:limit]

    return pkgs


def export_csv(rows: List[Tuple[str, float]], csv_path: Path) -> None:
    """
    Write the current table to *csv_path*.

    CSV schema:
      package, size_kib, size_human
    """
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["package", "size_kib", "size_human"])
        for name, size_kib in rows:
            writer.writerow([name, f"{size_kib:.2f}", human_readable(size_kib)])


def print_table(
    rows: List[Tuple[str, float]],
    use_rich: bool = True,
    verbose: bool = False,
    csv_path: Path | None = None,
) -> None:
    """
    Pretty-print the package table to stdout.
    """
    use_rich = bool(use_rich and _RICH_AVAILABLE)

    if use_rich:
        console = Console()
        table = Table(show_header=True, header_style="bold")
        table.add_column("Package", justify="left", no_wrap=True)
        table.add_column("Installed Size", justify="right")

        for name, size_kib in rows:
            size_text = human_readable(size_kib) if size_kib > 0 else "N/A"
            table.add_row(name, size_text)

        console.print(table)
        if verbose and csv_path is not None:
            console.print(f"[green]CSV written to:[/green] {csv_path}")
        return

    # Plain-text fallback
    header_pkg = "Package"
    header_size = "Installed Size"
    print(f"{header_pkg:<33} {header_size:>12}")
    print("-" * 47)
    for name, size_kib in rows:
        size_text = human_readable(size_kib) if size_kib > 0 else "N/A"
        print(f"{name:<33} {size_text:>12}")

    if verbose and csv_path is not None:
        print(f"[INFO] CSV written to: {csv_path}")


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
    parser.add_argument(
        "--no-rich",
        action="store_true",
        help="disable Rich-based pretty printing even if Rich is installed",
    )
    parser.add_argument(
        "--csv",
        action="store_true",
        help=(
            "export the current table to "
            "$HOME/exported_csv_logs/sort_pkg_by_size/<timestamp>/"
            "pkg_by_size_report.csv"
        ),
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="print extra diagnostic information (e.g. CSV path)",
    )
    args = parser.parse_args()

    table = build_table(limit=args.limit)

    csv_path: Path | None = None
    if args.csv:
        csv_path = default_csv_path()
        export_csv(table, csv_path)

    print_table(
        table,
        use_rich=not args.no - rich,
        verbose=args.verbose,
        csv_path=csv_path,
    )


# ---------------------------------------------------------------------------#
if __name__ == "__main__":  # noqa: D401
    main()
