#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
search-cargo-pkg.py — Search crates.io and list only crates that are installable via `cargo install`

Definition of “installable”
---------------------------
A crate is considered installable if its latest published version declares at least one
binary target (kind == "bin") in crates.io metadata. This is independent of your local network
state or registry mirrors. Optionally, you can add --verify to run `cargo install --dry-run`
for each candidate to confirm that an actual installation would succeed in your environment.

Why not only use `cargo install --dry-run`?
------------------------------------------
Dry-runs are authoritative *but* can fail for incidental reasons (offline mode, proxy issues,
auth to private registries, temporarily unavailable index). That yields false negatives.
We therefore gate on metadata first (fast, deterministic), with optional verification.

Usage examples
--------------
# Show the top 30 installable matches for "cargo", sorted by downloads
search-cargo-pkg.py cargo --sort downloads --limit 30

# Prefer newest updates first; print a CSV
search-cargo-pkg.py http --sort latest --limit 25 --csv http_tools.csv

# Verify with cargo’s dry-run using nightly toolchain (does not change your global default)
search-cargo-pkg.py rip --verify --toolchain nightly

# Non-interactive install: pick rows 1..3
search-cargo-pkg.py lint --limit 20 --yes 1-3

# Pass-through install knobs (applied to --verify / install)
search-cargo-pkg.py zed --features 'some,feat' --locked --install

# Exact-name bias (rank exact match first) and fetch more candidates from crates.io
search-cargo-pkg.py cargo --size 200 --exact

Columns
-------
- Crate:     crate name
- Version:   latest (max_stable_version if present; otherwise newest_version)
- Updated:   crates.io update timestamp (UTC)
- DL30:      recent (last 90d) download proxy from crates.io (approximate)
- Summary:   description (truncated)

Exit codes
----------
0 success; 1 no matches; 2 usage / network errors during search; non-zero from installer is propagated on failure.

Requirements
------------
- Python 3.8+
- `requests`, `python-dateutil`, optional `rich` for pretty tables
- `cargo` present in PATH for --verify / --install

"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable, Optional

# Optional niceties
try:
    from rich.console import Console
    from rich.table import Table
    RICH = True
    console = Console()
except Exception:
    RICH = False
    class _C:  # minimal shim
        def print(self, *a, **k): print(*a)
    console = _C()

try:
    import requests
except ModuleNotFoundError:
    print("This script requires 'requests'. Install with: python -m pip install requests", file=sys.stderr)
    sys.exit(2)

try:
    from dateutil.parser import isoparse
except Exception:
    def isoparse(s: str) -> datetime:
        # Basic fallback for Z/UTC iso strings
        return datetime.fromisoformat(s.replace("Z", "+00:00"))

# ----------------------------- Constants ---------------------------------

CRATES_API = "https://crates.io/api/v1"
UA = {"Accept": "application/json", "User-Agent": "search-cargo-pkg/1.1"}

# ----------------------------- Model -------------------------------------

@dataclass
class CrateRow:
    name: str
    version: str
    has_bin: bool
    updated: datetime
    downloads_recent: int
    description: str

# ----------------------------- Helpers -----------------------------------

def http_get_json(url: str, params: Optional[dict]=None, timeout: int=25) -> dict:
    r = requests.get(url, params=params, headers=UA, timeout=timeout)
    r.raise_for_status()
    return r.json()

def crates_search(query: str, size: int, page: int) -> list[CrateRow]:
    """
    Pull a page of search results; then for each crate resolve its latest version
    and inspect targets to determine if any 'bin' target exists.
    """
    params = {"q": query, "per_page": size, "page": page}
    data = http_get_json(f"{CRATES_API}/crates", params=params)

    results: list[CrateRow] = []
    for c in data.get("crates", []):
        name = c["id"]
        # Prefer a stable version if available
        version = c.get("max_stable_version") or c.get("newest_version") or ""
        updated = isoparse(c.get("updated_at") or "1970-01-01T00:00:00Z").astimezone(timezone.utc)
        dl = int(c.get("recent_downloads") or 0)
        desc = (c.get("description") or "").strip()

        has_bin = crate_version_has_bin(name, version)
        results.append(CrateRow(name=name, version=version, has_bin=has_bin,
                                updated=updated, downloads_recent=dl, description=desc))
    return results

def crate_version_has_bin(name: str, version: str) -> bool:
    """
    Ask crates.io for a specific version details and check its targets.
    Endpoint: /crates/{crate}/{version}
    """
    try:
        data = http_get_json(f"{CRATES_API}/crates/{name}/{version}")
        vers = data.get("version") or {}
        targets = vers.get("targets") or []
        for t in targets:
            # target example: {"kind": ["bin"], "name": "mybin", ...}
            kinds = t.get("kind") or []
            if "bin" in kinds:
                return True
        return False
    except Exception:
        # If version lookup fails for transient reasons, be conservative (not installable)
        return False

def sort_rows(rows: list[CrateRow], key: str, exact: Optional[str]) -> list[CrateRow]:
    if exact:
        # Bubble exact match to top if present
        rows.sort(key=lambda r: (r.name != exact, ), reverse=False)
    if key == "latest":
        rows.sort(key=lambda r: r.updated, reverse=True)
    elif key == "downloads":
        rows.sort(key=lambda r: r.downloads_recent, reverse=True)
    elif key == "name":
        rows.sort(key=lambda r: r.name.lower())
    return rows

def parse_ranges(spec: str, max_idx: int) -> list[int]:
    out: set[int] = set()
    for tok in re.split(r"[\s,]+", spec.strip()):
        if not tok:
            continue
        m = re.fullmatch(r"(\d+)-(\d+)", tok)
        if m:
            a, b = int(m.group(1)), int(m.group(2))
            if a < 1 or b > max_idx or a > b:
                raise ValueError(f"Range out of bounds: {tok} (1..{max_idx})")
            out.update(range(a, b + 1))
        elif tok.isdigit():
            i = int(tok)
            if i < 1 or i > max_idx:
                raise ValueError(f"Index out of bounds: {i} (1..{max_idx})")
            out.add(i)
        else:
            raise ValueError(f"Invalid token: {tok}")
    return sorted(out)

def cargo_verify(name: str, args) -> tuple[bool, str]:
    """
    Optionally confirm with `cargo install --dry-run` that the crate resolves and
    that at least one binary can be built in the current environment.
    """
    cmd = ["cargo"]
    if args.toolchain:
        cmd.append(f"+{args.toolchain}")
    cmd += ["install", "--dry-run", "--quiet"]
    if args.locked:
        cmd.append("--locked")
    if args.features:
        cmd += ["--features", args.features]
    if args.version:
        cmd += ["--version", args.version]
    cmd.append(name)
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=args.timeout)
        if p.returncode == 0:
            return True, "ok"
        msg = (p.stderr or p.stdout or "").strip().splitlines()
        return False, (msg[0] if msg else "non-zero exit")
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except FileNotFoundError:
        return False, "cargo not found"

def print_table(rows: list[CrateRow], query: str) -> None:
    if RICH:
        tab = Table(title=f"crates.io installable: “{query}”")
        tab.add_column("#", justify="right")
        tab.add_column("Crate")
        tab.add_column("Version", justify="center")
        tab.add_column("Updated (UTC)", justify="center")
        tab.add_column("DL30", justify="right")
        tab.add_column("Summary")
        for i, r in enumerate(rows, 1):
            tab.add_row(
                str(i),
                f"[bold]{r.name}[/]",
                r.version or "—",
                r.updated.strftime("%Y-%m-%d"),
                f"{r.downloads_recent:,}",
                (r.description or "")[:90],
            )
        console.print(tab)
    else:
        print(f'crates.io installable: "{query}"')
        for i, r in enumerate(rows, 1):
            print(f"{i:>3}. {r.name:28} {r.version:10} {r.updated:%Y-%m-%d} DL30={r.downloads_recent:>8}  {(r.description or '')[:80]}")

def do_install(picks: list[str], args) -> int:
    if not picks:
        console.print("[yellow]No selection; nothing to install.[/yellow]")
        return 0
    cmd = ["cargo"]
    if args.toolchain:
        cmd.append(f"+{args.toolchain}")
    cmd.append("install")
    if args.locked:
        cmd.append("--locked")
    if args.features:
        cmd += ["--features", args.features]
    if args.version:
        cmd += ["--version", args.version]
    cmd += picks
    console.print(f"[cyan]>[/cyan] {' '.join(shlex.quote(x) for x in cmd)}")
    return subprocess.call(cmd)

# ----------------------------- Main --------------------------------------

def main() -> None:
    epilog = """\
Sorting:
  latest     → descending by crates.io updated_at (UTC)
  downloads  → descending by recent_downloads
  name       → alphabetical

Verification:
  --verify runs `cargo install --dry-run` for each candidate under your flags.
  Use --toolchain nightly to scope nightly only here. Your global default is unchanged.

Selections:
  Use --yes "1 2 5-7" for non-interactive install, or --install to be prompted.
"""
    ag = argparse.ArgumentParser(
        description="Search crates.io and show only crates that expose binary targets (installable via cargo install).",
        epilog=epilog,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ag.add_argument("query", help="search term")
    ag.add_argument("--limit", type=int, default=20, help="maximum rows to display")
    ag.add_argument("--size", type=int, default=100, help="crates.io results to fetch before filtering")
    ag.add_argument("--page", type=int, default=1, help="page number (1-based)")
    ag.add_argument("--sort", choices=("latest", "downloads", "name"), default="latest", help="sorting criterion")
    ag.add_argument("--exact", action="store_true", help="rank exact name match first if present")

    # Probe / install tuning
    ag.add_argument("--verify", action="store_true", help="confirm candidates with `cargo install --dry-run`")
    ag.add_argument("--timeout", type=int, default=25, help="seconds per verify run")
    ag.add_argument("--toolchain", help="cargo toolchain to use for verify/install (e.g., nightly, stable, 1.81.0)")
    ag.add_argument("--features", help="feature list to enable for verify/install")
    ag.add_argument("--locked", action="store_true", help="pass --locked to cargo for reproducible resolution")
    ag.add_argument("--version", help="semver requirement to constrain crate version")

    # Output / install
    ag.add_argument("--csv", metavar="FILE", help="export table to CSV")
    ag.add_argument("--install", action="store_true", help="prompt to install selected crates")
    ag.add_argument("--yes", metavar="SEL", help='non-interactive selection like "1 2 5-7"')

    args = ag.parse_args()

    # Query crates.io
    try:
        rows = crates_search(args.query, size=args.size, page=args.page)
    except requests.HTTPError as e:
        console.print(f"[red]HTTP error from crates.io:[/red] {e}")
        sys.exit(2)
    except Exception as e:
        console.print(f"[red]Failed to query crates.io:[/red] {e}")
        sys.exit(2)

    # Keep only those with bin targets
    rows = [r for r in rows if r.has_bin]

    if not rows:
        console.print("[yellow]No installable crates matched your query (based on metadata).[/yellow]")
        sys.exit(1)

    # Optional verify step to weed out environment issues
    if args.verify:
        verified: list[CrateRow] = []
        for r in rows:
            ok, why = cargo_verify(r.name, args)
            if ok:
                verified.append(r)
        rows = verified
        if not rows:
            console.print("[yellow]All candidates failed verification in your local environment.[/yellow]")
            sys.exit(1)

    # Sort / trim
    exact = args.query if args.exact else None
    rows = sort_rows(rows, key=args.sort, exact=exact)
    rows = rows[: args.limit]

    # Show
    print_table(rows, args.query)

    # CSV
    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(["rank", "crate", "version", "updated_utc", "downloads_recent", "summary"])
            for i, r in enumerate(rows, 1):
                w.writerow([i, r.name, r.version, r.updated.strftime("%Y-%m-%d"), r.downloads_recent, r.description])
        console.print(f"[green]CSV saved →[/green] {args.csv}")

    # Install
    if args.yes:
        idx = parse_ranges(args.yes, max_idx=len(rows))
        picks = [rows[i-1].name for i in idx]
        rc = do_install(picks, args)
        sys.exit(rc)

    if args.install:
        try:
            sel = input("Enter crate numbers to install (e.g. 1 2 5 10-12): ").strip()
            idx = parse_ranges(sel, max_idx=len(rows))
            picks = [rows[i-1].name for i in idx]
            rc = do_install(picks, args)
            sys.exit(rc)
        except Exception as e:
            console.print(f"[red]Installation aborted:[/red] {e}")
            sys.exit(1)

if __name__ == "__main__":
    main()

