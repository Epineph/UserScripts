#!/usr/bin/env python3
"""
space-scout — fast, precise directory size reconnaissance.

Summary
    • Scans "user" scope (-u/--user) ≡ $HOME, "system" scope (-s/--system) ≡ /
      and/or explicit path lists (-p/--path/--path-list).
    • Recursion control: -r/--recursive and/or -d/--depth N (depth alone implies recursion).
    • Case-insensitive flags are accepted via upper-case aliases (-S/--SYSTEM etc.).
    • Requires root (sudo) if: -s|--system is present, or path-list includes /home
      or any path outside $HOME. Enforces your stated rule.
    • Uses GNU `du` by default for speed; falls back to a safe Python walker.
    • Rich table output (and optional JSON) with human-readable sizes, per-root totals,
      and top-N largest entries.

Exit codes
    0  success
    1  usage / validation error
    2  privilege requirement not met (sudo/root required by your rules)
    3  runtime failure (I/O error, missing dependencies, etc.)

Examples
    space-scout -u                              # scan $HOME (depth=1 summary)
    space-scout -u -r -d 2                      # $HOME, recursively to depth 2
    space-scout -s                              # scan / (requires sudo), depth=1
    space-scout -s -p "/var,/etc /opt" -d 2     # system scope, restricted paths
    space-scout -p "/home" -d 1                 # implies sudo by rule (/home)
    space-scout -u -p "~/data,/var/log" -d 3    # $HOME + extra paths (sudo if needed)
    space-scout -u -n 50 --json                 # top 50 entries in JSON
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Iterable, List, Tuple, Dict

# ───────────────────────────────────── Utilities ─────────────────────────────────────


def is_root() -> bool:
    try:
        return os.geteuid() == 0  # POSIX
    except AttributeError:
        return False


def expand_normalize(p: str) -> Path:
    return Path(os.path.abspath(os.path.expanduser(p))).resolve()


def parse_path_list(items: List[str] | None) -> List[Path]:
    """
    Accepts multiple -p occurrences; each may contain commas and/or whitespace.
    Quotes are honored (user shell handles them); here we split on commas and spaces.
    """
    if not items:
        return []
    tokens: List[str] = []
    for raw in items:
        # split on commas first, then whitespace inside each chunk
        for chunk in raw.split(","):
            chunk = chunk.strip()
            if not chunk:
                continue
            tokens.extend(shlex.split(chunk))
    # normalize, drop duplicates while preserving order
    seen = set()
    out: List[Path] = []
    for t in tokens:
        p = expand_normalize(t)
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out


def under(child: Path, parent: Path) -> bool:
    try:
        child.relative_to(parent)
        return True
    except Exception:
        return False


def classify_and_require_root(
    want_user: bool, want_system: bool, explicit_paths: List[Path], home: Path
) -> Tuple[List[Path], bool]:
    """
    Build the list of roots to scan and determine whether, per your rules,
    root privileges are REQUIRED (not just 'helpful').
    """
    roots: List[Path] = []
    requires_root = False

    if want_user:
        roots.append(home)

    if want_system:
        # If -s is supplied, user mandated that / is in scope unless paths are provided.
        if explicit_paths:
            # Only include explicit paths; still considered "system" per rule.
            roots.extend(explicit_paths)
        else:
            roots.append(Path("/"))
        requires_root = True  # Your spec: -s implies root required.

    # If -s was not supplied, explicit paths alone can still imply system context:
    if not want_system and explicit_paths:
        roots.extend([p for p in explicit_paths if p not in roots])
        for p in explicit_paths:
            if str(p) == "/home" or not under(p, home):
                # your rule: /home or outside $HOME ⇒ sudo required.
                requires_root = True

    # If nothing was specified, default to -u semantics
    if not roots:
        roots = [home]

    # Collapse duplicates
    uniq: List[Path] = []
    seen = set()
    for r in roots:
        if r not in seen:
            seen.add(r)
            uniq.append(r)

    return uniq, requires_root


def have(cmd: str) -> bool:
    return shutil.which(cmd) is not None

# ───────────────────────────── Engines: du and Python ─────────────────────────────


def run_du(root: Path, depth: int, xdev: bool, apparent: bool) -> List[Tuple[int, str]]:
    """
    Returns list of (size_bytes, path) up to max-depth for the root. Uses GNU du.
    """
    cmd = ["du", "-b", "--max-depth", str(depth)]
    if xdev:
        cmd.append("-x")
    if apparent:
        # with -b, this is redundant but harmless
        cmd.append("--apparent-size")
    cmd.append(str(root))
    try:
        out = subprocess.check_output(
            cmd, stderr=subprocess.DEVNULL, text=True)
    except FileNotFoundError as e:
        raise RuntimeError("GNU 'du' not found") from e
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"'du' failed on {root}") from e

    results: List[Tuple[int, str]] = []
    for line in out.splitlines():
        if "\t" not in line:
            # Some locales may use spaces; be tolerant
            parts = line.strip().split(None, 1)
        else:
            parts = line.strip().split("\t", 1)
        if len(parts) != 2:
            continue
        try:
            size = int(parts[0])
        except ValueError:
            continue
        path = parts[1]
        results.append((size, path))
    return results


def walk_python(root: Path, depth: int) -> List[Tuple[int, str]]:
    """
    Conservative pure-Python fallback roughly emulating 'du --apparent-size'.
    Sums file sizes (st_size), ignores symlink targets, and handles permissions gracefully.
    """
    root = root.resolve()
    levels: Dict[Path, int] = {root: 0}
    sizes: Dict[Path, int] = {root: 0}
    out: List[Tuple[int, str]] = []

    def add_size(path: Path, inc: int):
        # bubble up toward root, recording sizes for ancestors within depth
        cur = path
        while True:
            if cur not in levels:
                # compute level lazily
                try:
                    lvl = len(cur.relative_to(root).parts)
                except Exception:
                    break
                levels[cur] = lvl
            lvl = levels[cur]
            if lvl > depth:
                break
            sizes[cur] = sizes.get(cur, 0) + inc
            if cur == root:
                break
            cur = cur.parent

    for dirpath, dirnames, filenames in os.walk(root, onerror=lambda e: None, followlinks=False):
        d = Path(dirpath)
        # Prune traversal beyond requested depth
        try:
            lvl = len(d.relative_to(root).parts)
        except Exception:
            continue
        levels[d] = lvl
        if lvl >= depth:
            dirnames[:] = []  # stop descending
        # files
        for fn in filenames:
            p = d / fn
            try:
                st = p.lstat()
                if not os.path.islink(p):
                    add_size(d, int(st.st_size))
            except Exception:
                continue

    # Emit all directories we measured
    for p, sz in sizes.items():
        out.append((sz, str(p)))
    return out

# ───────────────────────────────────── Rendering ─────────────────────────────────────


def print_rich_table(per_root: Dict[str, List[Tuple[int, str]]], top: int, json_out: bool):
    if json_out:
        payload = []
        for root, rows in per_root.items():
            rows_sorted = sorted(rows, key=lambda t: t[0], reverse=True)[:top]
            payload.append({
                "root": root,
                "entries": [{"bytes": sz, "path": path} for sz, path in rows_sorted],
                "total_bytes": sum(sz for sz, _ in rows),
            })
        print(json.dumps(payload, indent=2))
        return

    try:
        from rich.console import Console
        from rich.table import Table
        from rich.filesize import decimal as human
        from rich import box
    except Exception:
        # Fallback: plain text
        for root, rows in per_root.items():
            print(f"\n[ROOT] {root}")
            rows_sorted = sorted(rows, key=lambda t: t[0], reverse=True)[:top]
            for sz, path in rows_sorted:
                print(f"{sz:>12} B  {path}")
            total = sum(sz for sz, _ in rows)
            print(f"Total: {total} B")
        return

    c = Console()
    for root, rows in per_root.items():
        rows_sorted = sorted(rows, key=lambda t: t[0], reverse=True)[:top]
        total = sum(sz for sz, _ in rows)
        t = Table(title=f"[bold]Disk usage under[/] {root}  •  total {human(total)}",
                  box=box.SIMPLE_HEAVY, show_lines=False, expand=True)
        t.add_column("Rank", justify="right")
        t.add_column("Size", justify="right")
        t.add_column("Path", justify="left", overflow="fold")
        for idx, (sz, path) in enumerate(rows_sorted, 1):
            t.add_row(str(idx), human(sz), path)
        c.print(t)

# ────────────────────────────────────── Main ──────────────────────────────────────


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="space-scout",
        formatter_class=argparse.RawTextHelpFormatter,
        description=(
            "Locate large directories quickly.\n"
            "Depth semantics: depth=0 shows only the root itself; depth=1 includes its immediate children, etc.\n"
            "If -d/--depth is given without -r/--recursive, recursion is implied."
        ),
    )

    # Case-insensitive via aliases
    parser.add_argument("-u", "--user", "-U", "--USER", action="store_true",
                        help="Include user scope ($HOME). Default if nothing else is provided.")
    parser.add_argument("-s", "--system", "-S", "--SYSTEM", action="store_true",
                        help="Include system scope (/). Requires root by rule you specified.")
    parser.add_argument("-p", "--path", "--path-list", action="append", metavar="LIST",
                        help='Extra roots (comma/space separated). Example: -p "/var,/opt /srv"')

    parser.add_argument("-r", "--recursive", action="store_true",
                        help="Recurse (full) unless -d limits it.")
    parser.add_argument("-d", "--depth", type=int, default=None,
                        help="Max depth (>=0). If given without -r, recursion is implied.")

    parser.add_argument("-n", "--top", type=int, default=25,
                        help="Show top-N entries per root (default: 25).")
    parser.add_argument("--engine", choices=["du", "python"], default="du",
                        help="Computation engine (default: du).")
    parser.add_argument("--xdev", "--one-file-system", action="store_true",
                        help="Do not cross filesystem boundaries (du -x; python: stay within same device).")
    parser.add_argument("--apparent-size", action="store_true",
                        help="Prefer apparent size (du: --apparent-size). Default behavior already uses bytes.")
    parser.add_argument("--json", action="store_true",
                        help="JSON output instead of a table (useful for scripting).")
    parser.add_argument("--debug", action="store_true",
                        help="Verbose errors to stderr.")

    args = parser.parse_args(argv)

    home = Path(os.path.expanduser("~")).resolve()
    explicit = parse_path_list(args.path)

    # Decide recursion & depth
    if args.depth is None:
        depth = 1 if not args.recursive else 2**31 - 1  # 'infinite' for du
    else:
        if args.depth < 0:
            print("Depth must be >= 0", file=sys.stderr)
            return 1
        depth = args.depth
        # depth specified implies recursion even if -r omitted
        args.recursive = True

    roots, must_be_root = classify_and_require_root(
        args.user, args.system, explicit, home)

    if must_be_root and not is_root():
        print("Root privileges required by policy (system scope or /home/outside $HOME). "
              "Re-run via: sudo space-scout ...", file=sys.stderr)
        return 2

    # Compute per-root results
    per_root: Dict[str, List[Tuple[int, str]]] = {}

    for root in roots:
        try:
            if args.engine == "du":
                if not have("du"):
                    raise RuntimeError(
                        "GNU 'du' not found; use --engine python")
                eff_depth = depth if args.recursive else 0
                rows = run_du(root, eff_depth, xdev=args.xdev,
                              apparent=args.apparent_size)
            else:
                eff_depth = depth if args.recursive else 0
                rows = walk_python(root, eff_depth)
        except Exception as e:
            if args.debug:
                print(f"[error] {e}", file=sys.stderr)
            return 3

        per_root[str(root)] = rows

    print_rich_table(per_root, top=args.top, json_out=args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
