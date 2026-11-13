#!/usr/bin/env python
"""
disk_usage_inspector.py — focused disk usage overview for a few roots.

Default roots: / and $HOME

- Uses `du` to summarize directory sizes up to a given depth.
- Uses `find` to locate large files above a threshold.
- Prints compact tables for quick “what is eating space?” inspection.

Requires:
  - Python 3.x
  - GNU du, find
Optional:
  - rich (for nicer tables): pip install rich
"""

import argparse
import os
import shutil
import subprocess
import sys
from typing import Dict, List, Tuple

try:
    from rich.console import Console
    from rich.table import Table
    HAVE_RICH = True
except ImportError:
    HAVE_RICH = False
    Console = None
    Table = None

# ──────────────────────────────────────────────────────────────────────────────
# Helpers: size formatting, path truncation
# ──────────────────────────────────────────────────────────────────────────────


def humanize_bytes(num: int) -> str:
    """Convert bytes to a human-readable string (IEC units)."""
    n = float(num)
    units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    for u in units:
        if n < 1024.0 or u == units[-1]:
            return f"{n:7.1f}{u}"
        n /= 1024.0
    return f"{num:d}B"


def truncate_path(path: str, max_width: int) -> str:
    """Truncate long paths from the left, keeping the tail visible."""
    if max_width <= 0 or len(path) <= max_width:
        return path
    return "…" + path[-(max_width - 1):]


def rel_depth(root: str, path: str) -> int:
    """Depth of `path` relative to `root` in components."""
    root = os.path.abspath(root)
    path = os.path.abspath(path)
    if path == root:
        return 0
    rel = os.path.relpath(path, root)
    if rel == ".":
        return 0
    return rel.count(os.sep) + 1


# ──────────────────────────────────────────────────────────────────────────────
# Data collection using du/find
# ──────────────────────────────────────────────────────────────────────────────


def run_du_for_root(root: str, depth: int, excludes: List[str],
                    use_sudo: bool) -> List[Tuple[int, str]]:
    """
  Run du -B1 -x --max-depth=depth for a single root.

  Returns: list of (size_bytes, path).
  """
    root = os.path.abspath(root)
    cmd = []
    if use_sudo:
        cmd.append("sudo")
    cmd += ["du", "-B1", "-x", "--max-depth", str(depth)]
    for g in excludes:
        cmd.append(f"--exclude={g}")
    cmd.append(root)

    try:
        out = subprocess.check_output(cmd,
                                      stderr=subprocess.DEVNULL,
                                      text=True)
    except subprocess.CalledProcessError as e:
        print(f"ERR: du failed for root {root}: {e}", file=sys.stderr)
        return []

    entries: List[Tuple[int, str]] = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t", 1)
        if len(parts) != 2:
            parts = line.split(None, 1)
            if len(parts) != 2:
                continue
        size_str, path = parts
        try:
            size = int(size_str)
        except ValueError:
            continue
        entries.append((size, path))
    return entries


def run_find_large_files(root: str, min_size: str, excludes: List[str],
                         use_sudo: bool) -> List[Tuple[int, str, str]]:
    """
  Use find to locate files >= min_size under root.

  min_size: string like "200M", "1G" etc. passed directly to find -size +X.
  Returns: list of (size_bytes, path, root).
  """
    root = os.path.abspath(root)
    cmd: List[str] = []
    if use_sudo:
        cmd.append("sudo")
    cmd += ["find", root, "-xdev"]

    if excludes:
        cmd.append("(")
        for i, g in enumerate(excludes):
            if i > 0:
                cmd.append("-o")
            cmd += ["-path", g]
        cmd += [")", "-prune", "-o"]

    cmd += ["-type", "f", "-size", f"+{min_size}", "-printf", "%s\t%p\n"]

    try:
        out = subprocess.check_output(cmd,
                                      stderr=subprocess.DEVNULL,
                                      text=True)
    except subprocess.CalledProcessError as e:
        print(f"ERR: find failed for root {root}: {e}", file=sys.stderr)
        return []

    files: List[Tuple[int, str, str]] = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
        size_str, path = parts
        try:
            size = int(size_str)
        except ValueError:
            continue
        files.append((size, path, root))
    return files


# ──────────────────────────────────────────────────────────────────────────────
# Printing: rich tables if available, otherwise plain text
# ──────────────────────────────────────────────────────────────────────────────


def print_dir_tables(dirs_by_root: Dict[str, List[Tuple[int, str]]],
                     top_n: int) -> None:
    cols = shutil.get_terminal_size((120, 40)).columns
    # Reserve some width for rank/size/depth; rest for path
    path_width = max(20, cols - 30)

    for root, entries in dirs_by_root.items():
        if not entries:
            continue
        entries_sorted = sorted(entries, key=lambda t: t[0], reverse=True)
        top = entries_sorted[:top_n]

        if HAVE_RICH:
            console = Console()
            table = Table(title=f"Top {len(top)} directories under {root}",
                          show_lines=False)
            table.add_column("#", justify="right", no_wrap=True)
            table.add_column("Size", justify="right", no_wrap=True)
            table.add_column("Depth", justify="right", no_wrap=True)
            table.add_column("Path", overflow="fold")

            for idx, (size, path) in enumerate(top, start=1):
                depth = rel_depth(root, path)
                table.add_row(str(idx), humanize_bytes(size), str(depth), path)
            console.print(table)
        else:
            print(f"\n== Top {len(top)} directories under {root} ==")
            print(f"{'#':>3} {'Size':>10} {'d':>2}  Path")
            print("-" * min(cols, 120))
            for idx, (size, path) in enumerate(top, start=1):
                depth = rel_depth(root, path)
                p_tr = truncate_path(path, path_width)
                print(
                    f"{idx:>3} {humanize_bytes(size):>10} {depth:>2}  {p_tr}")


def print_file_table(files: List[Tuple[int, str, str]],
                     top_n_files: int) -> None:
    if not files or top_n_files <= 0:
        return

    cols = shutil.get_terminal_size((120, 40)).columns
    path_width = max(20, cols - 35)

    files_sorted = sorted(files, key=lambda t: t[0], reverse=True)
    top = files_sorted[:top_n_files]

    if HAVE_RICH:
        console = Console()
        table = Table(title=f"Top {len(top)} largest files", show_lines=False)
        table.add_column("#", justify="right", no_wrap=True)
        table.add_column("Size", justify="right", no_wrap=True)
        table.add_column("Root", justify="left", no_wrap=True)
        table.add_column("Path", overflow="fold")

        for idx, (size, path, root) in enumerate(top, start=1):
            table.add_row(str(idx), humanize_bytes(size), root, path)
        console.print(table)
    else:
        print(f"\n== Top {len(top)} largest files ==")
        print(f"{'#':>3} {'Size':>10} Root        Path")
        print("-" * min(cols, 120))
        for idx, (size, path, root) in enumerate(top, start=1):
            p_tr = truncate_path(path, path_width)
            print(f"{idx:>3} {humanize_bytes(size):>10} "
                  f"{root:<10} {p_tr}")


# ──────────────────────────────────────────────────────────────────────────────
# CLI
# ──────────────────────────────────────────────────────────────────────────────


def parse_args(argv: List[str]) -> argparse.Namespace:
    home = os.path.expanduser("~")
    parser = argparse.ArgumentParser(description=(
        "Inspect disk usage for a small set of roots using du/find. "
        "Default roots are '/' and $HOME."))
    parser.add_argument("-r",
                        "--roots",
                        nargs="+",
                        default=["/", home],
                        help="Roots to scan (default: / and $HOME).")
    parser.add_argument(
        "-d",
        "--depth",
        type=int,
        default=3,
        help="Max directory depth for du summaries (default: 3).")
    parser.add_argument(
        "-n",
        "--top-dirs",
        type=int,
        default=40,
        help="How many directories to show per root (default: 40).")
    parser.add_argument("-N",
                        "--top-files",
                        type=int,
                        default=40,
                        help="How many largest files to show (default: 40).")
    parser.add_argument(
        "-m",
        "--min-file-size",
        default="200M",
        help=("Threshold for 'large files' passed to find -size +X "
              "(default: 200M)."))
    parser.add_argument("-x",
                        "--exclude",
                        default="",
                        help=("Comma-separated path globs to exclude "
                              "(applies to du and find)."))
    parser.add_argument(
        "--sudo",
        action="store_true",
        help="Use sudo for du/find calls instead of running script as root.")
    return parser.parse_args(argv)


def main(argv: List[str]) -> int:
    args = parse_args(argv)

    excludes: List[str] = []
    if args.exclude:
        excludes = [g.strip() for g in args.exclude.split(",") if g.strip()]

    roots = [os.path.abspath(r) for r in args.roots]

    print("Roots:", ", ".join(roots))
    print(f"Directory depth: {args.depth}")
    print(f"Top dirs per root: {args.top_dirs}")
    print(f"Top files: {args.top_files}")
    print(f"Large file threshold: >= {args.min_file_size}")
    if excludes:
        print("Excludes:", ", ".join(excludes))
    if args.sudo:
        print("Using sudo for du/find.\n")
    else:
        print("Not using sudo (you may see some permission-denied gaps).\n")

    # Collect directory info per root
    dirs_by_root: Dict[str, List[Tuple[int, str]]] = {}
    for root in roots:
        print(f"• Summarizing directories under {root} ...", flush=True)
        dirs = run_du_for_root(root, args.depth, excludes, args.sudo)
        dirs_by_root[root] = dirs

    # Collect large files across all roots
    all_files: List[Tuple[int, str, str]] = []
    if args.top_files > 0:
        for root in roots:
            print(f"• Finding large files under {root} ...", flush=True)
            files = run_find_large_files(root, args.min_file_size, excludes,
                                         args.sudo)
            all_files.extend(files)

    # Print results
    print_dir_tables(dirs_by_root, args.top_dirs)
    if all_files:
        print_file_table(all_files, args.top_files)

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
