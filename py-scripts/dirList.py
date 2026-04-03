#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dirlist.py – Extended directory lister
=====================================

A friendly, *portable* replacement for `ls`/`lsd` that shows permissions in **both**
symbolic and octal form and can optionally print an ASCII tree.

Features
--------
* Accepts **multiple input paths** (defaults to current working directory).
* `-R/--recursive` – recurse into sub‑directories.
* `-t/--tree`      – render the listing as an ASCII tree (automatically enabled
  when `--recursive` is given unless explicitly disabled).
* `-d/--depth N`   – limit recursion depth (N = 1–3). A value of *‑1* (default)
  means *unlimited* depth. Ignored unless `--recursive` is active.
* Prints: `perm_sym perm_oct user group size date‑modified name` for every entry.

Example output
--------------
```text
/home/user/projects
PERMS     OCT USER     GROUP      SIZE        DATE MODIFIED      NAME
 drwxr-xr-x 755 user     user       4.0 KiB 2025-06-05 10:30 src
 -rw-r--r-- 644 user     user       1.2 KiB 2025-06-04 16:22 README.md
```

Quick reference
~~~~~~~~~~~~~~~
| Command                                         | What it does                               |
|-------------------------------------------------|--------------------------------------------|
| `dirlist.py`                                    | list current directory                     |
| `dirlist.py /etc /var`                          | list two directories                       |
| `dirlist.py -R -d 2`                            | recursive list, depth 2, tree view         |
| `dirlist.py -R --tree=false ~/data`             | recursive, *flat* listing                 |

See also the **full CLI help** (`dirlist.py -h`) which embeds these examples so
that *users always have usage hints at their fingertips*.
"""

from __future__ import annotations

import argparse
import os
import sys
import stat
import pwd
import grp
import textwrap
from datetime import datetime
from pathlib import Path
from typing import Iterable, List, Tuple

# ────────────────────────────────────────────────────────────
# Permission helpers
# ────────────────────────────────────────────────────────────

def symbolic_perms(mode: int) -> str:
    """Return symbolic rwx string including directory flag (e.g. drwxr‑xr‑x)."""
    is_dir = "d" if stat.S_ISDIR(mode) else "-"
    bits = (
        (stat.S_IRUSR, "r"), (stat.S_IWUSR, "w"), (stat.S_IXUSR, "x"),
        (stat.S_IRGRP, "r"), (stat.S_IWGRP, "w"), (stat.S_IXGRP, "x"),
        (stat.S_IROTH, "r"), (stat.S_IWOTH, "w"), (stat.S_IXOTH, "x"),
    )
    return is_dir + "".join(ch if mode & bit else "-" for bit, ch in bits)


def octal_perms(mode: int) -> str:
    """Return three‑digit octal permission string (e.g. 755)."""
    return f"{mode & 0o777:o}".zfill(3)


# ────────────────────────────────────────────────────────────
# Size helper – binary (IEC) prefixes
# ────────────────────────────────────────────────────────────

def human_size(num_bytes: int) -> str:
    units = ("B", "KiB", "MiB", "GiB", "TiB", "PiB")
    size = float(num_bytes)
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:>4.1f} {unit}"
        size /= 1024


# ────────────────────────────────────────────────────────────
# Directory traversal (depth‑first)
# ────────────────────────────────────────────────────────────

def iter_path(root: Path, depth_limit: int, prefix: List[str] | None = None) -> Iterable[Tuple[List[str], Path]]:
    """Yield (prefix, Path) tuples depth‑first with pretty‑printing helpers."""
    prefix = prefix or []
    try:
        entries = sorted(root.iterdir(), key=lambda p: p.name.lower())
    except PermissionError:
        print(f"[permission denied] {root}", file=sys.stderr)
        return

    for idx, entry in enumerate(entries):
        is_last = idx == len(entries) - 1
        branch = "└── " if is_last else "├── "
        new_prefix = prefix + [branch]
        yield new_prefix, entry
        if entry.is_dir(follow_symlinks=False) and depth_limit != 0:
            extension = "    " if is_last else "│   "
            yield from iter_path(
                entry,
                depth_limit - 1 if depth_limit > 0 else depth_limit,
                prefix + [extension],
            )


# ────────────────────────────────────────────────────────────
# Formatting helpers
# ────────────────────────────────────────────────────────────

def format_line(path: Path, st) -> str:
    user = pwd.getpwuid(st.st_uid).pw_name
    group = grp.getgrgid(st.st_gid).gr_name
    ts = datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M")
    return (
        f"{symbolic_perms(st.st_mode)} "
        f"{octal_perms(st.st_mode)} "
        f"{user:<8} {group:<8} {human_size(st.st_size):>9} {ts} {path.name}"
    )


# ────────────────────────────────────────────────────────────
# Core listing logic
# ────────────────────────────────────────────────────────────

def list_dir(path: Path, args: argparse.Namespace) -> None:
    if not path.exists():
        print(f"✖ {path}: no such file or directory", file=sys.stderr)
        return

    banner = str(path.resolve())
    header = "PERMS     OCT USER     GROUP      SIZE        DATE MODIFIED      NAME"
    print(f"\n{banner}")
    print(header)

    if args.recursive:
        for prefix, entry in iter_path(path, args.depth):
            st = entry.lstat()
            line = format_line(entry, st)
            if args.tree:
                tree_prefix = "".join(prefix[:-1]) + prefix[-1]
                print(f"{tree_prefix}{line}")
            else:
                print(line)
    else:
        for entry in sorted(path.iterdir(), key=lambda p: p.name.lower()):
            print(format_line(entry, entry.lstat()))


# ────────────────────────────────────────────────────────────
# Argument parsing & entry point
# ────────────────────────────────────────────────────────────

def build_parser() -> argparse.ArgumentParser:
    example_text = textwrap.dedent(
        """Examples:
  dirlist.py                       # list current directory (flat)\n  dirlist.py /etc /var             # list multiple directories (flat)\n  dirlist.py -R -d 2               # tree, recurse to depth 2\n  dirlist.py -R --tree=false .     # recurse but keep flat listing\n  dirlist.py -R ~/data             # unlimited depth tree\n  dirlist.py -d 3 /tmp             # depth ignored because -R not set\n"""
    )

    parser = argparse.ArgumentParser(
        prog="dirlist.py",
        description="""Extended directory lister (symbolic+octal perms, tree view, depth limit).""",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=example_text,
    )

    parser.add_argument(
        "paths",
        nargs="*",
        default=["."],
        metavar="PATH",
        help="File or directory paths (default: current directory).",
    )
    parser.add_argument(
        "-R",
        "--recursive",
        action="store_true",
        help="Recurse into sub‑directories.",
    )
    parser.add_argument(
        "-t",
        "--tree",
        dest="tree",
        action="store_true",
        help="Show results as an ASCII tree.",
    )
    parser.add_argument(
        "--tree=false",
        dest="tree",
        action="store_false",
        help="Disable tree view (use with -R for flat recursive listing).",
    )
    parser.add_argument(
        "-d",
        "--depth",
        type=int,
        default=-1,
        metavar="N",
        choices=[-1, 1, 2, 3],
        help="Limit recursion depth to N (1–3). -1 means unlimited (default).",
    )
    return parser


def main(argv: List[str] | None = None) -> None:
    argv = argv if argv is not None else sys.argv[1:]
    parser = build_parser()
    args = parser.parse_args(argv)

    # Implicit tree view when -R provided and user didn't decide.
    if args.recursive and not args.tree and "--tree=false" not in argv:
        args.tree = True

    if not args.recursive and args.depth != -1:
        print("⚠ Ignoring --depth because --recursive was not supplied.", file=sys.stderr)

    for raw_path in args.paths:
        list_dir(Path(raw_path).expanduser(), args)


if __name__ == "__main__":
    main()

