#!/usr/bin/env python3
"""fs_search.py — Flexible filesystem search tool.

A companion to your disk_usage_report script, but for name/path-based search.

Features:
  - Search one or more roots for files, directories, symlinks, or all types.
  - Filter by name substrings, regex, extensions, size, and modification time.
  - Exclude directory prefixes (/proc, /sys, /dev, /run, /tmp, /var/tmp, ...).
  - Optional Rich-based table output.
  - Optional CSV export of all matches.

Typical usage examples:

  # Find anything with 'chrome' in the name under / and /home:
  fs-search --roots / /home --name chrome

  # Only .log or .txt files modified after 2025-12-01:
  fs-search --roots /var/log --type file --ext log txt --after 2025-12-01

  # Export all matches under /home containing 'nvim' to CSV:
  fs-search --roots /home --path nvim --csv -v
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import stat
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable, Iterator, List, Optional, Sequence

try:
    from rich.console import Console
    from rich.table import Table

    _RICH_AVAILABLE = True
except Exception:  # pragma: no cover - optional dependency
    Console = None  # type: ignore[assignment]
    Table = None  # type: ignore[assignment]
    _RICH_AVAILABLE = False

# ─────────────────────────────── Utilities ───────────────────────────────


def normalize_paths(paths: Iterable[str]) -> List[str]:
    """Normalize a list of paths to absolute, real (symlink-resolved) paths."""
    out: List[str] = []
    for p in paths:
        if not p:
            continue
        out.append(os.path.realpath(os.path.abspath(os.path.expanduser(p))))
    return out


def is_under(path: str, prefixes: Sequence[str]) -> bool:
    """Return True if *path* is equal to or inside any directory in *prefixes*."""
    for prefix in prefixes:
        if not prefix:
            continue
        if path == prefix:
            return True
        if path.startswith(prefix.rstrip(os.sep) + os.sep):
            return True
    return False


def default_csv_path(script_stem: str, filename: str) -> Path:
    """Return a timestamped CSV path under $HOME/exported_csv_logs/script_stem."""
    base = (Path(os.path.expanduser("~")) / "exported_csv_logs" / script_stem /
            "logs" / datetime.now().strftime("%Y%m%d_%H%M%S"))
    base.mkdir(parents=True, exist_ok=True)
    return base / filename


_SIZE_UNITS = {
    "b": 1,
    "kb": 1000,
    "mb": 1000**2,
    "gb": 1000**3,
    "tb": 1000**4,
    "kib": 1024,
    "mib": 1024**2,
    "gib": 1024**3,
    "tib": 1024**4,
}


def parse_size(text: str) -> int:
    """Parse a human-ish size like '10M', '2GiB', '500kB' into bytes.

  Rules:
    - Plain integer → bytes.
    - Suffix (case-insensitive) can be:
        k, m, g, t, kb, mb, gb, tb, kib, mib, gib, tib
    - 'k', 'm', 'g', 't' are treated as kib, mib, gib, tib (1024-based).
  """
    s = text.strip()
    if not s:
        raise ValueError("empty size string")

    m = re.fullmatch(r"(?i)\s*(\d+)\s*([kmgt]?i?b?)?\s*", s)
    if not m:
        raise ValueError(f"cannot parse size: {text!r}")

    number = int(m.group(1))
    unit = (m.group(2) or "").lower()

    if unit == "":
        return number

    # Canonicalise short units.
    if unit in {"k", "m", "g", "t"}:
        unit = unit + "ib"  # treat k, m, g, t as kib, mib, gib, tib

    if unit not in _SIZE_UNITS:
        raise ValueError(f"unknown size unit in {text!r}")

    return number * _SIZE_UNITS[unit]


def human_bytes(num: int) -> str:
    """Render byte count in a 1-decimal power-of-1024 representation."""
    units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    value = float(num)
    for unit in units:
        if value < 1024.0 or unit == units[-1]:
            return f"{value:6.1f} {unit}"
        value /= 1024.0
    return f"{num} B"


def fmt_mtime(ts: Optional[float]) -> str:
    if ts is None:
        return ""
    return datetime.fromtimestamp(ts).isoformat(sep=" ", timespec="seconds")


# ─────────────────────────────── Data Model ──────────────────────────────


@dataclass
class Match:
    path: str
    kind: str  # 'file', 'dir', 'symlink', 'other'
    size: Optional[int]
    mtime: Optional[float]


# ─────────────────────────────── Core Search ─────────────────────────────


def path_kind(mode: int) -> str:
    if stat.S_ISREG(mode):
        return "file"
    if stat.S_ISDIR(mode):
        return "dir"
    if stat.S_ISLNK(mode):
        return "symlink"
    return "other"


def kind_allowed(kind: str, wanted: Sequence[str]) -> bool:
    if not wanted:
        return True
    if "all" in wanted:
        return True
    return kind in wanted


def match_filters(
    m: Match,
    base_name: str,
    path: str,
    *,
    name_terms: Sequence[str],
    path_terms: Sequence[str],
    regex: Optional[re.Pattern[str]],
    exts: Sequence[str],
    min_size: Optional[int],
    max_size: Optional[int],
    after: Optional[datetime],
    before: Optional[datetime],
) -> bool:
    """Return True if *m* satisfies all active filters.

  Semantics:
    - name_terms: OR on base name (case-insensitive).
    - path_terms: OR on full path (case-insensitive).
    - regex: applied to full path if given.
    - exts: applied to file extension (dirs ignore this filter).
    - size filters: only for regular files.
    - time filters: for both files and directories.
  """
    # Name terms
    if name_terms:
        b = base_name.lower()
        if not any(term in b for term in name_terms):
            return False

    # Path terms
    if path_terms:
        p = path.lower()
        if not any(term in p for term in path_terms):
            return False

    # Regex
    if regex is not None and not regex.search(path):
        return False

    # Extension
    if exts and m.kind == "file":
        ext = Path(base_name).suffix.lstrip(".").lower()
        if ext not in exts:
            return False

    # Size filters (files only)
    if m.kind == "file" and m.size is not None:
        if min_size is not None and m.size < min_size:
            return False
        if max_size is not None and m.size > max_size:
            return False

    # Time filters
    if m.mtime is not None:
        dt = datetime.fromtimestamp(m.mtime)
        if after is not None and dt < after:
            return False
        if before is not None and dt > before:
            return False

    return True


def walk_matches(
    roots: Sequence[str],
    exclude: Sequence[str],
    *,
    type_filter: Sequence[str],
    name_terms: Sequence[str],
    path_terms: Sequence[str],
    regex: Optional[re.Pattern[str]],
    exts: Sequence[str],
    min_size: Optional[int],
    max_size: Optional[int],
    after: Optional[datetime],
    before: Optional[datetime],
) -> Iterator[Match]:
    """Yield Match objects satisfying filters under given roots."""
    roots_norm = normalize_paths(roots)
    exclude_norm = normalize_paths(exclude)

    for root in roots_norm:
        if not os.path.isdir(root):
            print(
                f"[WARN] Root is not a directory or does not exist: {root}",
                file=sys.stderr,
            )
            continue

        for dirpath, dirnames, filenames in os.walk(root, topdown=True):
            dirpath_real = os.path.realpath(dirpath)

            if is_under(dirpath_real, exclude_norm):
                dirnames[:] = []
                continue

            # Directory itself
            try:
                st_dir = os.lstat(dirpath_real)
            except OSError:
                st_dir = None

            if st_dir is not None:
                kind = path_kind(st_dir.st_mode)
                base = os.path.basename(dirpath_real) or dirpath_real
                m = Match(
                    path=dirpath_real,
                    kind=kind,
                    size=None,
                    mtime=st_dir.st_mtime,
                )
                if kind_allowed(kind, type_filter) and match_filters(
                        m,
                        base,
                        dirpath_real,
                        name_terms=name_terms,
                        path_terms=path_terms,
                        regex=regex,
                        exts=exts,
                        min_size=min_size,
                        max_size=max_size,
                        after=after,
                        before=before,
                ):
                    yield m

            # Files etc.
            for name in filenames:
                fpath = os.path.join(dirpath_real, name)
                try:
                    st = os.lstat(fpath)
                except OSError:
                    continue

                kind = path_kind(st.st_mode)
                m = Match(
                    path=fpath,
                    kind=kind,
                    size=st.st_size if stat.S_ISREG(st.st_mode) else None,
                    mtime=st.st_mtime,
                )

                if not kind_allowed(kind, type_filter):
                    continue

                if match_filters(
                        m,
                        name,
                        fpath,
                        name_terms=name_terms,
                        path_terms=path_terms,
                        regex=regex,
                        exts=exts,
                        min_size=min_size,
                        max_size=max_size,
                        after=after,
                        before=before,
                ):
                    yield m


# ─────────────────────────────── Reporting ───────────────────────────────


def print_report(
    matches: Sequence[Match],
    *,
    use_rich: bool,
    verbose: bool,
) -> None:
    use_rich = bool(use_rich and _RICH_AVAILABLE)

    if use_rich:
        console = Console()
        console.print()
        console.print(
            f"[bold]== Filesystem Search Report ({len(matches)} matches) ==[/bold]"
        )
        console.print()

        table = Table(
            title="Matches",
            show_header=True,
            header_style="bold",
        )
        table.add_column("#", justify="right")
        table.add_column("Kind", width=8)
        table.add_column("Size", justify="right", no_wrap=True)
        table.add_column("Modified", no_wrap=True)
        table.add_column("Path", overflow="fold")

        for idx, m in enumerate(matches, start=1):
            size_str = human_bytes(m.size) if m.size is not None else ""
            table.add_row(
                str(idx),
                m.kind,
                size_str,
                fmt_mtime(m.mtime),
                m.path,
            )

        console.print(table)
        console.print()
        if verbose and not _RICH_AVAILABLE:
            console.print(
                "[yellow]Rich is not available; using plain text.[/yellow]")
        console.print()
        return

    # Plain text
    print()
    print(f"=== Filesystem Search Report ({len(matches)} matches) ===")
    print()
    for idx, m in enumerate(matches, start=1):
        size_str = human_bytes(m.size) if m.size is not None else ""
        print(
            f"{idx:4d}. {m.kind:8s} {size_str:>12s} {fmt_mtime(m.mtime)}  {m.path}"
        )
    print()


def export_csv(matches: Sequence[Match], csv_path: Path) -> None:
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(
            ["index", "kind", "size_bytes", "size_human", "mtime", "path"])
        for idx, m in enumerate(matches, start=1):
            writer.writerow([
                idx,
                m.kind,
                m.size if m.size is not None else "",
                human_bytes(m.size) if m.size is not None else "",
                fmt_mtime(m.mtime),
                m.path,
            ])


# ─────────────────────────────── CLI ───────────────────────────────


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    default_roots = ["."]
    default_excludes = ["/proc", "/sys", "/dev", "/run", "/tmp", "/var/tmp"]

    p = argparse.ArgumentParser(description=(
        "Search the filesystem for files, directories, and symlinks matching "
        "name, path, size, and time filters."))

    p.add_argument(
        "-r",
        "--roots",
        nargs="+",
        default=default_roots,
        help="Root directories to search (default: current directory).",
    )

    p.add_argument(
        "-x",
        "--exclude",
        nargs="*",
        default=default_excludes,
        help=
        ("Directory prefixes to exclude entirely (default: /proc /sys /dev /run "
         "/tmp /var/tmp)."),
    )

    p.add_argument(
        "-t",
        "--type",
        nargs="+",
        choices=["file", "dir", "symlink", "other", "all"],
        default=["all"],
        help=(
            "What to include. Multiple values allowed. 'all' means everything. "
            "Default: all."),
    )

    p.add_argument(
        "-n",
        "--name",
        nargs="*",
        default=[],
        help=("Case-insensitive substrings that must appear in the base name. "
              "Multiple values are OR-ed."),
    )

    p.add_argument(
        "-p",
        "--path",
        nargs="*",
        default=[],
        help=
        ("Case-insensitive substrings that must appear somewhere in the full "
         "path. Multiple values are OR-ed."),
    )

    p.add_argument(
        "--regex",
        default=None,
        help="Optional Python regular expression applied to the full path.",
    )

    p.add_argument(
        "-e",
        "--ext",
        nargs="*",
        default=[],
        help=
        ("File extensions (without leading dot). Only affects regular files; "
         "directories ignore this filter."),
    )

    p.add_argument(
        "--min-size",
        default=None,
        help=("Minimum file size, e.g. '10M', '2GiB'. Only applies to regular "
              "files."),
    )

    p.add_argument(
        "--max-size",
        default=None,
        help=(
            "Maximum file size, e.g. '500K', '1GiB'. Only applies to regular "
            "files."),
    )

    p.add_argument(
        "--after",
        default=None,
        help=("Only include entries modified on/after this ISO date-time "
              "(e.g. 2025-12-05 or 2025-12-05T12:00:00)."),
    )

    p.add_argument(
        "--before",
        default=None,
        help=("Only include entries modified on/before this ISO date-time."),
    )

    p.add_argument(
        "--sort",
        choices=["path", "size", "mtime"],
        default="path",
        help="Sort order for the final result list (default: path).",
    )

    p.add_argument(
        "-l",
        "--limit",
        type=int,
        default=None,
        help="Optional maximum number of matches to show (after sorting).",
    )

    p.add_argument(
        "--no-rich",
        action="store_true",
        help="Disable Rich pretty-printing even if the library is installed.",
    )

    p.add_argument(
        "--csv",
        action="store_true",
        help=
        ("Export all matches to CSV under $HOME/exported_csv_logs/fs_search/ "
         "logs/<timestamp>/."),
    )

    p.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Print extra diagnostic information (e.g. CSV path).",
    )

    return p.parse_args(argv)


def parse_iso_dt(text: Optional[str]) -> Optional[datetime]:
    if not text:
        return None
    s = text.strip()
    if not s:
        return None
    try:
        if "T" in s:
            return datetime.fromisoformat(s)
        return datetime.fromisoformat(s + "T00:00:00")
    except ValueError as exc:
        raise SystemExit(f"Invalid ISO date/time: {text!r}: {exc}") from exc


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)

    name_terms = [s.lower() for s in (args.name or [])]
    path_terms = [s.lower() for s in (args.path or [])]
    exts = [s.lower().lstrip(".") for s in (args.ext or [])]

    regex: Optional[re.Pattern[str]]
    if args.regex:
        try:
            regex = re.compile(args.regex)
        except re.error as exc:
            raise SystemExit(f"Invalid regex {args.regex!r}: {exc}") from exc
    else:
        regex = None

    min_size = None
    max_size = None
    if args.min_size is not None:
        try:
            min_size = parse_size(args.min_size)
        except ValueError as exc:
            raise SystemExit(str(exc)) from exc
    if args.max_size is not None:
        try:
            max_size = parse_size(args.max_size)
        except ValueError as exc:
            raise SystemExit(str(exc)) from exc

    after = parse_iso_dt(args.after)
    before = parse_iso_dt(args.before)

    matches = list(
        walk_matches(
            roots=args.roots,
            exclude=args.exclude,
            type_filter=args.type,
            name_terms=name_terms,
            path_terms=path_terms,
            regex=regex,
            exts=exts,
            min_size=min_size,
            max_size=max_size,
            after=after,
            before=before,
        ))

    # Sorting and limiting.
    if args.sort == "path":
        matches.sort(key=lambda m: m.path)
    elif args.sort == "size":
        matches.sort(key=lambda m: (-1 if m.size is None else m.size))
    elif args.sort == "mtime":
        matches.sort(key=lambda m: (m.mtime or 0.0))

    if args.limit is not None and args.limit >= 0:
        matches = matches[:args.limit]

    csv_path: Optional[Path] = None
    if args.csv:
        csv_path = default_csv_path("fs_search", "fs_search.csv")
        export_csv(matches, csv_path)

    use_rich = not args.no_rich
    print_report(matches, use_rich=use_rich, verbose=args.verbose)

    if args.verbose and csv_path is not None:
        print(f"[INFO] CSV written to: {csv_path}")

    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv[1:]))
