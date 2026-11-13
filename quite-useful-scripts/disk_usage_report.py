#!/usr/bin/env python3
"""
disk_usage_report.py — Scan directories recursively and report biggest space users.

Features:
  - Recursive scan of one or more root paths.
  - Summarize directory sizes up to a given depth "bucket".
  - Report top-N largest directories and files.
  - Skips system pseudo-filesystems by default (/proc, /sys, /dev, /run, ...).

Examples:
  # Simple overview of the whole system (excluding pseudo FS):
  python3 disk_usage_report.py

  # Focus only on the LUKS/LVM-based system (/ and /home) and ignore /shared:
  python3 disk_usage_report.py --roots / /home --exclude /shared

  # Deeper directory buckets and more items:
  python3 disk_usage_report.py --max-depth 3 --top-dirs 40 --top-files 60
"""

import argparse
import heapq
import os
import stat
import sys
from typing import Dict, Iterable, List, Set, Tuple


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
    out = []
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

    Example:
      root = "/"
      dirpath = "/usr/lib/python3.13/site-packages"
      max_depth = 2  → bucket = "/usr/lib"

      root = "/home/heini"
      dirpath = "/home/heini/.cache/pip/http"
      max_depth = 1  → bucket = "/home/heini/.cache"
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


# ─────────────────────────────── Core Logic ───────────────────────────────


def scan_roots(
    roots: List[str],
    exclude: List[str],
    max_depth: int,
    top_files_limit: int,
) -> Tuple[Dict[str, int], List[Tuple[int, str]], int]:
    """
    Walk given roots, accumulating directory "bucket" sizes and top files.

    Returns:
      dir_sizes:   dict mapping bucket_path → total size (bytes)
      top_files:   list of (size, path) tuples of largest files
      total_bytes: total size of all regular files scanned
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

            # Avoid crossing into mountpoints you explicitly excluded as roots
            # (we rely mainly on excludes; this is just a small safeguard).
            # You can extend this if needed.

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

    return dir_sizes, top_files, total_bytes


# ─────────────────────────────── Reporting ───────────────────────────────


def print_report(
    dir_sizes: Dict[str, int],
    top_files: List[Tuple[int, str]],
    total_bytes: int,
    top_dirs_limit: int,
) -> None:
    """
    Print a human-readable report of directory buckets and largest files.
    """
    print()
    print("=== Disk Usage Report ===")
    print()
    print(f"Total size of regular files scanned: {human_bytes(total_bytes)}")
    print()

    # Top directory buckets
    print(f"--- Top {top_dirs_limit} directory buckets ---")
    sorted_dirs = sorted(
        dir_sizes.items(),
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
    print(f"--- Top {len(top_files)} files by size ---")
    if not top_files:
        print("No files found.")
    else:
        # top_files is a min-heap; sort descending before printing
        for i, (size, path) in enumerate(
            sorted(top_files, key=lambda x: x[0], reverse=True),
            start=1,
        ):
            print(f"{i:3d}. {human_bytes(size)}  {path}")
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

    return parser.parse_args(argv)


def main(argv: List[str]) -> int:
    args = parse_args(argv)

    dir_sizes, top_files, total_bytes = scan_roots(
        roots=args.roots,
        exclude=args.exclude,
        max_depth=args.max_depth,
        top_files_limit=args.top_files,
    )

    print_report(
        dir_sizes=dir_sizes,
        top_files=top_files,
        total_bytes=total_bytes,
        top_dirs_limit=args.top_dirs,
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
