#!/usr/bin/env python3
"""
disk_usage_report.py — Scan directories recursively and report biggest space users.

Features:
  - Recursive scan of one or more root paths.
  - Summarize directory sizes up to a given depth "bucket".
  - Report top-N largest directories and files.
  - Skips system pseudo-filesystems by default (/proc, /sys, /dev, /run, ...).
  - Optional Rich-based pretty output.
  - Optional CSV export of the current report.

Examples:
  # Simple overview of the whole system (excluding pseudo FS):
  python3 disk_usage_report.py

  # Focus only on the LUKS/LVM-based system (/ and /home) and ignore /shared:
  python3 disk_usage_report.py --roots / /home --exclude /shared

  # Deeper directory buckets and more items:
  python3 disk_usage_report.py --max-depth 3 --top-dirs 40 --top-files 60

  # Export results to a CSV under $HOME/exported_csv_logs and show extra info:
  python3 disk_usage_report.py --csv --verbose
"""

import argparse
import csv
import heapq
import os
import stat
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable, List, Set, Tuple

# Rich is optional: if unavailable we fall back to plain text output.
try:
    from rich.console import Console
    from rich.table import Table

    _RICH_AVAILABLE = True
except Exception:  # pragma: no cover - optional dependency
    Console = None  # type: ignore[assignment]
    Table = None  # type: ignore[assignment]
    _RICH_AVAILABLE = False

# ─────────────────────────────── Utilities ───────────────────────────────


def human_bytes(num: int) -> str:
    """
    Convert a byte count into a human-readable string (KiB, MiB, GiB,...).

    Uses base 1024 units: KiB, MiB, GiB, TiB.
    """
    units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    value = float(num)
    for unit in units:
        if value < 1024.0 or unit == units[-1]:
            return f"{value:6.1f} {unit}"
        value /= 1024.0
    # Fallback; logically unreachable
    return f"{num} B"


def normalize_paths(paths: Iterable[str]) -> List[str]:
    """
    Normalize a list of paths into absolute, real (symlink-resolved) paths.
    """
    out: List[str] = []
    for p in paths:
        if not p:
            continue
        out.append(os.path.realpath(os.path.abspath(p)))
    return out


def is_under(path: str, prefixes: Set[str]) -> bool:
    """
    Return True if 'path' is equal to or inside any directory in 'prefixes'.
    """
    for prefix in prefixes:
        if path == prefix:
            return True
        # Ensure trailing separator to avoid /proc matching /procxyz
        if path.startswith(prefix.rstrip(os.sep) + os.sep):
            return True
    return False


def dir_bucket(root: str, dirpath: str, max_depth: int) -> str:
    """
    Map an absolute directory path into its "bucket" at the given max depth.
    """
    root = os.path.realpath(root)
    dirpath = os.path.realpath(dirpath)

    if dirpath == root:
        return root

    rel = os.path.relpath(dirpath, root)
    if rel == ".":
        return root

    parts = rel.split(os.sep)
    depth = min(len(parts), max_depth)
    bucket_path = os.path.join(root, *parts[:depth])
    return bucket_path


def add_top_file(
    heap: List[Tuple[int, str]],
    size: int,
    path: str,
    limit: int,
) -> None:
    """
    Maintain a min-heap of the largest 'limit' files.
    """
    if limit <= 0:
        return
    if size <= 0:
        return

    item = (size, path)
    if len(heap) < limit:
        heapq.heappush(heap, item)
    else:
        if size > heap[0][0]:
            heapq.heapreplace(heap, item)


def default_csv_path(script_stem: str, filename: str) -> Path:
    """
    Build a per-run CSV output path under $HOME/exported_csv_logs.

    Example for script_stem="disk_usage_report":
      $HOME/exported_csv_logs/disk_usage_report/logs/20251205_210101/filename
    """
    base = (
        Path(os.path.expanduser("~"))
        / "exported_csv_logs"
        / script_stem
        / "logs"
        / datetime.now().strftime("%Y%m%d_%H%M%S")
    )
    base.mkdir(parents=True, exist_ok=True)
    return base / filename


@dataclass
class ReportData:
    """
    Structured representation of the scan result for downstream consumers.
    """

    dir_sizes: Dict[str, int]
    top_files: List[Tuple[int, str]]
    total_bytes: int


# ─────────────────────────────── Core Logic ───────────────────────────────


def scan_roots(
    roots: List[str],
    exclude: List[str],
    max_depth: int,
    top_files_limit: int,
) -> ReportData:
    """
    Walk given roots, accumulating directory "bucket" sizes and top files.
    """
    roots = normalize_paths(roots)
    exclude_set = set(normalize_paths(exclude))
    dir_sizes: Dict[str, int] = {}
    top_files: List[Tuple[int, str]] = []
    total_bytes = 0

    for root in roots:
        if not os.path.isdir(root):
            print(
                f"[WARN] Root is not a directory or does not exist: {root}",
                file=sys.stderr,
            )
            continue

        for dirpath, dirnames, filenames in os.walk(root, topdown=True):
            dirpath_real = os.path.realpath(dirpath)

            # Skip excluded prefixes entirely
            if is_under(dirpath_real, exclude_set):
                dirnames[:] = []  # Do not descend further
                continue

            # Compute the bucket for this directory
            bucket = dir_bucket(root, dirpath_real, max_depth)

            # Iterate over files
            for name in filenames:
                fpath = os.path.join(dirpath_real, name)
                try:
                    st = os.lstat(fpath)
                except OSError:
                    # Permission error / broken symlink / transient file
                    continue

                # Only count regular files; skip sockets, FIFOs, etc.
                if not stat.S_ISREG(st.st_mode):
                    continue

                size = st.st_size
                total_bytes += size

                # Accumulate into bucket
                dir_sizes[bucket] = dir_sizes.get(bucket, 0) + size

                # Maintain top-N largest files
                add_top_file(top_files, size, fpath, top_files_limit)

    return ReportData(dir_sizes=dir_sizes, top_files=top_files, total_bytes=total_bytes)


# ─────────────────────────────── Reporting ───────────────────────────────


def export_csv(
    report: ReportData,
    top_dirs_limit: int,
    csv_path: Path,
) -> None:
    """
    Export directory buckets and top files into a single CSV.

    CSV schema:
      kind, rank, size_bytes, size_human, path
    """
    sorted_dirs = sorted(
        report.dir_sizes.items(),
        key=lambda kv: kv[1],
        reverse=True,
    )

    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["kind", "rank", "size_bytes", "size_human", "path"])

        # Directory buckets
        for rank, (path, size) in enumerate(
            sorted_dirs[:top_dirs_limit],
            start=1,
        ):
            writer.writerow(
                ["dir", rank, size, human_bytes(size).strip(), path],
            )

        # Top files
        for rank, (size, path) in enumerate(
            sorted(report.top_files, key=lambda x: x[0], reverse=True),
            start=1,
        ):
            writer.writerow(
                ["file", rank, size, human_bytes(size).strip(), path],
            )


def print_report(
    report: ReportData,
    top_dirs_limit: int,
    use_rich: bool = True,
    verbose: bool = False,
    csv_path: Path | None = None,
) -> None:
    """
    Print a human-readable report of directory buckets and largest files.
    """
    use_rich = bool(use_rich and _RICH_AVAILABLE)

    if use_rich:
        console = Console()
        console.print()
        console.print("[bold]== Disk Usage Report ==[/bold]")
        console.print()
        console.print(
            "Total size of regular files scanned: "
            f"[bold]{human_bytes(report.total_bytes)}[/bold]"
        )
        console.print()

        # Top directory buckets
        sorted_dirs = sorted(
            report.dir_sizes.items(),
            key=lambda kv: kv[1],
            reverse=True,
        )

        table_dirs = Table(
            title=f"Top {top_dirs_limit} directory buckets",
            show_header=True,
            header_style="bold",
        )
        table_dirs.add_column("#", justify="right")
        table_dirs.add_column("Size")
        table_dirs.add_column("Path", overflow="fold")

        if not sorted_dirs:
            console.print("No directories found.")
        else:
            for i, (path, size) in enumerate(
                sorted_dirs[:top_dirs_limit],
                start=1,
            ):
                table_dirs.add_row(str(i), human_bytes(size), path)
        console.print(table_dirs)
        console.print()

        # Top files
        table_files = Table(
            title=f"Top {len(report.top_files)} files by size",
            show_header=True,
            header_style="bold",
        )
        table_files.add_column("#", justify="right")
        table_files.add_column("Size")
        table_files.add_column("Path", overflow="fold")

        if not report.top_files:
            console.print("No files found.")
        else:
            for i, (size, path) in enumerate(
                sorted(report.top_files, key=lambda x: x[0], reverse=True),
                start=1,
            ):
                table_files.add_row(str(i), human_bytes(size), path)
        console.print(table_files)
        console.print()

        if verbose and csv_path is not None:
            console.print(f"[green]CSV written to:[/green] {csv_path}")
        console.print()
        return

    # Plain-text fallback (no Rich installed or explicitly disabled)
    print()
    print("=== Disk Usage Report ===")
    print()
    print(f"Total size of regular files scanned: {human_bytes(report.total_bytes)}")
    print()

    # Top directory buckets
    print(f"--- Top {top_dirs_limit} directory buckets ---")
    sorted_dirs = sorted(
        report.dir_sizes.items(),
        key=lambda kv: kv[1],
        reverse=True,
    )

    if not sorted_dirs:
        print("No directories found.")
    else:
        for i, (path, size) in enumerate(sorted_dirs[:top_dirs_limit], start=1):
            print(f"{i:3d}. {human_bytes(size)}  {path}")
    print()

    # Top files
    print(f"--- Top {len(report.top_files)} files by size ---")
    if not report.top_files:
        print("No files found.")
    else:
        for i, (size, path) in enumerate(
            sorted(report.top_files, key=lambda x: x[0], reverse=True),
            start=1,
        ):
            print(f"{i:3d}. {human_bytes(size)}  {path}")
    print()

    if verbose and csv_path is not None:
        print(f"[INFO] CSV written to: {csv_path}")
        print()


# ─────────────────────────────── CLI ───────────────────────────────


def parse_args(argv: List[str]) -> argparse.Namespace:
    """
    Parse command line options.
    """
    default_roots = ["/"]
    default_excludes = [
        "/proc",
        "/sys",
        "/dev",
        "/run",
        "/tmp",
        "/var/tmp",
        "/lost+found",
    ]

    parser = argparse.ArgumentParser(
        description=(
            "Recursively scan directories and report the largest space users "
            "(directory buckets and files)."
        )
    )

    parser.add_argument(
        "-r",
        "--roots",
        nargs="+",
        default=default_roots,
        help=(
            "Root directories to scan (default: /). "
            "Avoid overlapping roots like / and /home together, unless you "
            "know what you are doing."
        ),
    )

    parser.add_argument(
        "-x",
        "--exclude",
        nargs="*",
        default=default_excludes,
        help=(
            "Directories to exclude (prefix match). "
            "Default: /proc /sys /dev /run /tmp /var/tmp /lost+found"
        ),
    )

    parser.add_argument(
        "-d",
        "--max-depth",
        type=int,
        default=2,
        help=(
            "Maximum depth for directory buckets relative to each root. "
            "For example, with --max-depth 2, /usr/lib/python3.13 will be "
            "counted under /usr/lib. Default: 2."
        ),
    )

    parser.add_argument(
        "--top-dirs",
        type=int,
        default=30,
        help="Number of largest directory buckets to display (default: 30).",
    )

    parser.add_argument(
        "--top-files",
        type=int,
        default=50,
        help="Number of largest files to display (default: 50).",
    )

    parser.add_argument(
        "--no-rich",
        action="store_true",
        help="Disable Rich-based pretty printing even if Rich is installed.",
    )

    parser.add_argument(
        "--csv",
        action="store_true",
        help=(
            "Export the current report to a CSV under "
            "$HOME/exported_csv_logs/disk_usage_report/logs/<timestamp>/."
        ),
    )

    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Print extra diagnostic information (e.g. CSV path).",
    )

    return parser.parse_args(argv)


def main(argv: List[str]) -> int:
    args = parse_args(argv)

    report = scan_roots(
        roots=args.roots,
        exclude=args.exclude,
        max_depth=args.max_depth,
        top_files_limit=args.top_files,
    )

    csv_path: Path | None = None
    if args.csv:
        csv_path = default_csv_path(
            script_stem="disk_usage_report",
            filename="disk_usage_report.csv",
        )
        export_csv(
            report=report,
            top_dirs_limit=args.top_dirs,
            csv_path=csv_path,
        )

    use_rich = not args.no_rich
    print_report(
        report=report,
        top_dirs_limit=args.top_dirs,
        use_rich=use_rich,
        verbose=args.verbose,
        csv_path=csv_path,
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
