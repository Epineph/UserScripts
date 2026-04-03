#!/usr/bin/env python3
"""
disk_usage_report.py

Recursively scan one or more roots and report the largest space users.

Key properties:
  - Defends against overlapping roots by default.
  - Can stay on one filesystem per root (du -x style).
  - Deduplicates files by (st_dev, st_ino).
  - Can report either apparent size or allocated size.

Examples:
  # Whole root filesystem only, excluding pseudo filesystems:
  disk_usage_report --roots / --one-file-system

  # Root + home as separate filesystems:
  disk_usage_report --roots / /home --one-file-system --exclude /shared

  # Include /boot explicitly as its own filesystem:
  disk_usage_report --roots / /home /boot --one-file-system --top-files 100

  # Use apparent file size instead of allocated disk usage:
  disk_usage_report --roots / /home --one-file-system --size-mode apparent
"""

import argparse
import heapq
import os
import stat
import sys

from typing import Dict, Iterable, List, Set, Tuple


# -----------------------------------------------------------------------------
# Utilities
# -----------------------------------------------------------------------------


def human_bytes(num: int) -> str:
    """Convert bytes to a human-readable string."""
    units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    value = float(num)

    for unit in units:
        if value < 1024.0 or unit == units[-1]:
            return f"{value:6.1f} {unit}"
        value /= 1024.0

    return f"{num} B"


def normalize_paths(paths: Iterable[str]) -> List[str]:
    """Normalize paths to unique absolute real paths, preserving order."""
    out: List[str] = []
    seen: Set[str] = set()

    for path in paths:
        if not path:
            continue

        norm = os.path.realpath(os.path.abspath(path))
        if norm in seen:
            continue

        seen.add(norm)
        out.append(norm)

    return out


def path_depth(path: str) -> int:
    """Return a simple depth metric for sorting roots parent-first."""
    stripped = path.strip(os.sep)
    if not stripped:
        return 0
    return len(stripped.split(os.sep))


def is_under(path: str, prefixes: Set[str]) -> bool:
    """Return True if path is equal to or under any prefix."""
    for prefix in prefixes:
        if path == prefix:
            return True
        if path.startswith(prefix.rstrip(os.sep) + os.sep):
            return True
    return False


def same_or_descendant(path: str, parent: str) -> bool:
    """Return True if path == parent or path is inside parent."""
    if path == parent:
        return True
    return path.startswith(parent.rstrip(os.sep) + os.sep)


def stat_dev(path: str) -> int:
    """Return filesystem device number for path."""
    return os.lstat(path).st_dev


def measured_size(st: os.stat_result, size_mode: str) -> int:
    """
    Return measured file size.

    size_mode:
      - apparent  -> st_size
      - allocated -> st_blocks * 512, fallback to st_size if unavailable
    """
    if size_mode == "apparent":
        return int(st.st_size)

    blocks = getattr(st, "st_blocks", None)
    if blocks is None:
        return int(st.st_size)

    return int(blocks) * 512


def dir_bucket(root: str, dirpath: str, max_depth: int) -> str:
    """
    Map dirpath into its bucket under root at relative depth max_depth.
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
    return os.path.join(root, *parts[:depth])


def add_top_file(
    heap: List[Tuple[int, str]],
    size: int,
    path: str,
    limit: int,
) -> None:
    """Maintain a min-heap of the largest files."""
    if limit <= 0 or size <= 0:
        return

    item = (size, path)

    if len(heap) < limit:
        heapq.heappush(heap, item)
        return

    if size > heap[0][0]:
        heapq.heapreplace(heap, item)


def prepare_roots(
    roots: List[str],
    allow_overlap: bool,
    one_file_system: bool,
) -> List[str]:
    """
    Normalize and optionally collapse overlapping roots.

    Important nuance:
      If --one-file-system is enabled, overlapping roots on different devices
      are allowed, because scanning the parent root will not descend into the
      child filesystem anyway.
    """
    roots = normalize_paths(roots)

    if allow_overlap:
        return roots

    roots_sorted = sorted(
        roots,
        key=lambda p: (path_depth(p), len(p), p),
    )

    kept: List[str] = []

    for candidate in roots_sorted:
        drop = False

        for parent in kept:
            if not same_or_descendant(candidate, parent):
                continue

            if one_file_system:
                try:
                    if stat_dev(candidate) != stat_dev(parent):
                        continue
                except OSError:
                    pass

            print(
                f"[WARN] Dropping overlapping root: {candidate} "
                f"(already covered by {parent})",
                file=sys.stderr,
            )
            drop = True
            break

        if not drop:
            kept.append(candidate)

    return kept


# -----------------------------------------------------------------------------
# Core scan logic
# -----------------------------------------------------------------------------


def scan_roots(
    roots: List[str],
    exclude: List[str],
    max_depth: int,
    top_files_limit: int,
    one_file_system: bool,
    allow_overlap: bool,
    size_mode: str,
) -> Tuple[Dict[str, int], List[Tuple[int, str]], int]:
    """
    Walk roots and accumulate:

      - bucket sizes
      - top files
      - total measured bytes

    Files are deduplicated by (st_dev, st_ino).
    """
    roots = prepare_roots(
        roots=roots,
        allow_overlap=allow_overlap,
        one_file_system=one_file_system,
    )
    exclude_set = set(normalize_paths(exclude))

    dir_sizes: Dict[str, int] = {}
    top_files: List[Tuple[int, str]] = []
    total_bytes = 0
    seen_files: Set[Tuple[int, int]] = set()

    for root in roots:
        if not os.path.isdir(root):
            print(
                f"[WARN] Root is not a directory or does not exist: {root}",
                file=sys.stderr,
            )
            continue

        try:
            root_dev = stat_dev(root)
        except OSError as exc:
            print(
                f"[WARN] Could not stat root {root}: {exc}",
                file=sys.stderr,
            )
            continue

        for dirpath, dirnames, filenames in os.walk(
            root,
            topdown=True,
            followlinks=False,
        ):
            dirpath_real = os.path.realpath(dirpath)

            if is_under(dirpath_real, exclude_set):
                dirnames[:] = []
                continue

            kept_dirnames: List[str] = []

            for dirname in dirnames:
                child = os.path.join(dirpath, dirname)
                child_real = os.path.realpath(child)

                if is_under(child_real, exclude_set):
                    continue

                if one_file_system:
                    try:
                        child_st = os.lstat(child)
                    except OSError:
                        continue

                    if stat.S_ISDIR(child_st.st_mode):
                        if child_st.st_dev != root_dev:
                            continue

                kept_dirnames.append(dirname)

            dirnames[:] = kept_dirnames
            bucket = dir_bucket(root, dirpath_real, max_depth)

            for filename in filenames:
                fpath = os.path.join(dirpath, filename)

                try:
                    st = os.lstat(fpath)
                except OSError:
                    continue

                if not stat.S_ISREG(st.st_mode):
                    continue

                file_key = (st.st_dev, st.st_ino)
                if file_key in seen_files:
                    continue

                seen_files.add(file_key)

                size = measured_size(st, size_mode)
                total_bytes += size
                dir_sizes[bucket] = dir_sizes.get(bucket, 0) + size

                add_top_file(
                    heap=top_files,
                    size=size,
                    path=os.path.realpath(fpath),
                    limit=top_files_limit,
                )

    return dir_sizes, top_files, total_bytes


# -----------------------------------------------------------------------------
# Reporting
# -----------------------------------------------------------------------------


def print_report(
    dir_sizes: Dict[str, int],
    top_files: List[Tuple[int, str]],
    total_bytes: int,
    top_dirs_limit: int,
    size_mode: str,
) -> None:
    """Print the final report."""
    print()
    print("=== Disk Usage Report ===")
    print()
    print(f"Size mode: {size_mode}")
    print(f"Total measured size of regular files scanned: {human_bytes(total_bytes)}")
    print()

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

    print(f"--- Top {len(top_files)} files by size ---")
    if not top_files:
        print("No files found.")
    else:
        for i, (size, path) in enumerate(
            sorted(top_files, key=lambda x: x[0], reverse=True),
            start=1,
        ):
            print(f"{i:3d}. {human_bytes(size)}  {path}")

    print()


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------


def parse_args(argv: List[str]) -> argparse.Namespace:
    """Parse command-line arguments."""
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
            "Root directories to scan. By default, overlapping roots are "
            "collapsed unless --allow-overlap is given."
        ),
    )

    parser.add_argument(
        "-x",
        "--exclude",
        nargs="*",
        default=default_excludes,
        help=(
            "Directories to exclude by prefix match. Default excludes: "
            "/proc /sys /dev /run /tmp /var/tmp /lost+found"
        ),
    )

    parser.add_argument(
        "-d",
        "--max-depth",
        type=int,
        default=2,
        help=(
            "Maximum depth for directory buckets relative to each root. "
            "Default: 2."
        ),
    )

    parser.add_argument(
        "--top-dirs",
        type=int,
        default=30,
        help="Number of largest directory buckets to display.",
    )

    parser.add_argument(
        "--top-files",
        type=int,
        default=50,
        help="Number of largest files to display.",
    )

    parser.add_argument(
        "--one-file-system",
        action="store_true",
        help=(
            "Do not descend into directories on a different filesystem than "
            "the current root (similar to du -x)."
        ),
    )

    parser.add_argument(
        "--allow-overlap",
        action="store_true",
        help=(
            "Allow overlapping roots. Dangerous unless you explicitly want "
            "double-counting behaviour."
        ),
    )

    parser.add_argument(
        "--size-mode",
        choices=("allocated", "apparent"),
        default="allocated",
        help=(
            "allocated = use st_blocks*512 (closer to disk usage); "
            "apparent = use st_size (logical file size). Default: allocated."
        ),
    )

    return parser.parse_args(argv)


def main(argv: List[str]) -> int:
    """Program entry point."""
    args = parse_args(argv)

    dir_sizes, top_files, total_bytes = scan_roots(
        roots=args.roots,
        exclude=args.exclude,
        max_depth=args.max_depth,
        top_files_limit=args.top_files,
        one_file_system=args.one_file_system,
        allow_overlap=args.allow_overlap,
        size_mode=args.size_mode,
    )

    print_report(
        dir_sizes=dir_sizes,
        top_files=top_files,
        total_bytes=total_bytes,
        top_dirs_limit=args.top_dirs,
        size_mode=args.size_mode,
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
