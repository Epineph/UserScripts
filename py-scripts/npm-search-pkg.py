#!/usr/bin/env python3
"""
Search npm registry, rank matches, optionally export, and install selected packages.

Analogy to the user's PyPI script:
- Fetches npm results via the official search endpoint.
- Enriches with last-month download counts and canonical release date.
- Sorts by latest release date, downloads, or search score.
- Pretty table output (rich) + optional CSV / PDF exports.
- Interactive "enumerated install" that accepts ranges (e.g., "1 3 5-7").
- Supports npm, pnpm, yarn, or bun as the package manager.

Usage examples
--------------
# Search for 'jupyter', show top 20 by downloads; no installation
./search-npm-enumerated-install.py jupyter --sort downloads --limit 20

# Same, but prompt to install via pnpm (global dev deps)
./search-npm-enumerated-install.py http --manager pnpm --global --dev --install

# Export to CSV and PDF, sorted by latest release date
./search-npm-enumerated-install.py react --sort latest --csv react.csv --pdf react.pdf

# JSON dump of the search result rows
./search-npm-enumerated-install.py astro --json out.json
"""
from __future__ import annotations

import argparse
import csv
import html
import json
import os
import pathlib
import re
import subprocess
import sys
import shlex
import time
from collections import namedtuple
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable, List, Optional

try:
    import requests
except ModuleNotFoundError:
    print("This script requires the 'requests' package. Install it with: python -m pip install requests", file=sys.stderr)
    sys.exit(1)

try:
    from dateutil.parser import isoparse  # type: ignore
except ModuleNotFoundError:
    print("This script requires 'python-dateutil'. Install it with: python -m pip install python-dateutil", file=sys.stderr)
    sys.exit(1)

try:
    from rich.console import Console
    from rich.table import Table
    RICH_OK = True
except ModuleNotFoundError:
    RICH_OK = False

# ---------------------------------------------------------------------
# Endpoints & constants
# ---------------------------------------------------------------------
SEARCH_URL = "https://registry.npmjs.org/-/v1/search"
PKG_META_URL = "https://registry.npmjs.org/{name}"
DOWNLOADS_URL = "https://api.npmjs.org/downloads/point/last-month/{name}"

CACHE_DIR = pathlib.Path.home() / ".cache" / "npm_rank"
CACHE_DIR.mkdir(parents=True, exist_ok=True)
HEADERS = {"Accept": "application/json", "User-Agent": "npm-enum/1.0"}

console = Console() if RICH_OK else None

@dataclass
class NpmPkg:
    """Container for a package row."""
    name: str
    version: str
    released: datetime
    downloads: int
    score: float
    description: str

# ---------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------
def parse_selection(selection: str, max_index: int) -> list[int]:
    """
    Parse user selection like: "1 2 5 10-12" → [1,2,5,10,11,12].
    Raises ValueError for invalid tokens or out-of-range indices.
    """
    indices: set[int] = set()
    tokens = re.split(r"[\s,]+", selection.strip())
    for token in tokens:
        if not token:
            continue
        m = re.match(r"^(\d+)-(\d+)$", token)
        if m:
            start, end = int(m.group(1)), int(m.group(2))
            if start < 1 or end > max_index or start > end:
                raise ValueError(f"Range '{token}' out of valid bounds 1-{max_index}")
            indices.update(range(start, end + 1))
        elif token.isdigit():
            idx = int(token)
            if idx < 1 or idx > max_index:
                raise ValueError(f"Index '{idx}' out of valid bounds 1-{max_index}")
            indices.add(idx)
        else:
            raise ValueError(f"Invalid token: '{token}'")
    return sorted(indices)

def _safe_get(url: str, timeout: int = 20) -> Optional[requests.Response]:
    try:
        r = requests.get(url, headers=HEADERS, timeout=timeout)
        r.raise_for_status()
        return r
    except Exception:
        return None

# ---------------------------------------------------------------------
# npm helpers
# ---------------------------------------------------------------------
def npm_search(query: str, size: int = 200) -> list[dict]:
    """
    Use npm official search endpoint. Returns a list of raw objects.
    Each object contains 'package' and 'score' among other fields.
    """
    params = {"text": query, "size": str(size)}
    try:
        r = requests.get(SEARCH_URL, headers=HEADERS, params=params, timeout=25)
        r.raise_for_status()
        data = r.json()
        return data.get("objects", [])
    except Exception:
        return []

def npm_package_meta(name: str) -> dict:
    """Fetch the full package metadata document."""
    r = _safe_get(PKG_META_URL.format(name=name), timeout=25)
    return r.json() if r else {}

def npm_downloads_last_month(name: str) -> int:
    """Return last-month download count (int)."""
    r = _safe_get(DOWNLOADS_URL.format(name=name), timeout=20)
    if not r:
        return 0
    try:
        return int(r.json().get("downloads", 0))
    except Exception:
        return 0

def normalize_row(obj: dict) -> NpmPkg | None:
    """
    Build a NpmPkg row from a search object, enriching with:
    - definitive release timestamp (from metadata 'time' field)
    - last-month downloads (npm downloads API)
    """
    pkg = obj.get("package") or {}
    name = pkg.get("name")
    version = pkg.get("version") or ""
    description = (pkg.get("description") or "")[:80]
    score = float(obj.get("score", {}).get("final", 0.0))

    if not name:
        return None

    # Fetch metadata + downloads
    meta = npm_package_meta(name)
    downloads = npm_downloads_last_month(name)

    # Determine release date:
    # prefer time[version], then 'time.modified', then search 'date'
    released_dt = None
    try:
        times = meta.get("time", {}) if isinstance(meta.get("time", {}), dict) else {}
        if version and version in times:
            released_dt = isoparse(times[version])
        elif "modified" in times:
            released_dt = isoparse(times["modified"])
    except Exception:
        released_dt = None

    if released_dt is None:
        # fallback to search object 'package.date' if present
        date_raw = pkg.get("date")
        try:
            released_dt = isoparse(date_raw) if date_raw else datetime(1970, 1, 1, tzinfo=timezone.utc)
        except Exception:
            released_dt = datetime(1970, 1, 1, tzinfo=timezone.utc)

    return NpmPkg(
        name=name,
        version=version,
        released=released_dt.astimezone(timezone.utc),
        downloads=downloads,
        score=score,
        description=description,
    )

# ---------------------------------------------------------------------
# Writers
# ---------------------------------------------------------------------
def write_csv(path: str, records: list[NpmPkg]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["rank", "package", "version", "released_utc", "downloads_30d", "score", "description"])
        for r, p in enumerate(records, 1):
            w.writerow([r, p.name, p.version, p.released.strftime("%Y-%m-%d"), p.downloads, f"{p.score:.3f}", p.description])

def write_json(path: str, records: list[NpmPkg]) -> None:
    data = [
        {
            "rank": r,
            "package": p.name,
            "version": p.version,
            "released_utc": p.released.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "downloads_30d": p.downloads,
            "score": round(p.score, 6),
            "description": p.description,
        }
        for r, p in enumerate(records, 1)
    ]
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)

def write_pdf(path: str, query: str, criterion: str, records: list[NpmPkg]) -> None:
    try:
        from reportlab.lib.pagesizes import letter
        from reportlab.lib.units import inch
        from reportlab.pdfgen.canvas import Canvas
    except ModuleNotFoundError:
        raise RuntimeError("python-reportlab missing.")
    PAGE_W, PAGE_H = letter
    margin, lh, fs = 0.6*inch, 0.22*inch, 9
    max_rows = int((PAGE_H - 2*margin - 1.6*lh)//lh)
    cvs = Canvas(path, pagesize=letter)
    cvs.setFont("Helvetica-Bold", 12)
    cvs.drawString(margin, PAGE_H-margin, f"npm search: “{query}”  (sorted by {criterion})")
    cvs.setFont("Helvetica", fs)
    y = PAGE_H-margin-1.4*lh
    hdr = ["#", "Package", "Version", "Released", "30-day DLs", "Score", "Summary"]
    col = [margin, margin+0.4*inch, margin+2.4*inch, margin+3.3*inch, margin+4.5*inch, margin+5.8*inch, margin+6.5*inch]
    for x, h in zip(col, hdr):
        cvs.drawString(x, y, h)
    y -= lh
    cvs.line(margin, y+2, PAGE_W-margin, y+2)
    for r, p in enumerate(records, 1):
        if r > max_rows:
            break
        cvs.drawString(col[0], y, str(r))
        cvs.drawString(col[1], y, p.name[:20])
        cvs.drawString(col[2], y, p.version[:12])
        cvs.drawString(col[3], y, p.released.strftime("%Y-%m-%d"))
        cvs.drawRightString(col[4]+0.6*inch, y, f"{p.downloads:,}")
        cvs.drawRightString(col[5]+0.6*inch, y, f"{p.score:.3f}")
        cvs.drawString(col[6], y, p.description[:80])
        y -= lh
    cvs.save()

# ---------------------------------------------------------------------
# Install helpers
# ---------------------------------------------------------------------
def build_install_cmd(manager: str, pkgs: list[str], global_flag: bool, dev_flag: bool) -> list[str]:
    """
    Construct the install command based on package manager.
    - manager ∈ {npm, pnpm, yarn, bun}
    - global_flag → global install
    - dev_flag → dev dependency (where applicable)
    """
    m = manager.lower()
    if m == "npm":
        cmd = ["npm", "install"]
        if global_flag:
            cmd.append("-g")
        if dev_flag:
            cmd.append("--save-dev")
        cmd.extend(pkgs)
        return cmd
    elif m == "pnpm":
        cmd = ["pnpm", "add"]
        if global_flag:
            cmd.append("-g")
        if dev_flag:
            cmd.append("-D")
        cmd.extend(pkgs)
        return cmd
    elif m == "yarn":
        if global_flag:
            # yarn classic: 'yarn global add'
            cmd = ["yarn", "global", "add"]
            if dev_flag:
                # 'global' ignores -D; keep consistent and omit
                pass
        else:
            cmd = ["yarn", "add"]
            if dev_flag:
                cmd.append("-D")
        cmd.extend(pkgs)
        return cmd
    elif m == "bun":
        cmd = ["bun", "add"]
        if global_flag:
            cmd.append("-g")
        if dev_flag:
            cmd.append("-d")
        cmd.extend(pkgs)
        return cmd
    else:
        raise ValueError(f"Unsupported manager: {manager}")

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------
def main() -> None:
    epilog = """\
Sorting:
  latest     → descending by release date (UTC)
  downloads  → descending by last-month downloads
  score      → descending by npm search score (quality/popularity/maintenance composite)

Install:
  Use --install to select rows (e.g., "1 2 5-7") for installation.
  Choose --manager npm|pnpm|yarn|bun, optionally --global and/or --dev.
"""
    ag = argparse.ArgumentParser(
        description="Search npm registry, rank matches, and optionally install selected packages.",
        epilog=epilog,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ag.add_argument("query", help="search term for npm packages")
    ag.add_argument("--sort", choices=("latest", "downloads", "score"), default="latest", help="sorting criterion for results")
    ag.add_argument("--limit", type=int, default=20, help="maximum number of packages to display")
    ag.add_argument("--threads", type=int, default=16, help="number of parallel threads for per-package enrichment")
    ag.add_argument("--size", type=int, default=200, help="how many matches to request from the search API before ranking/trim")
    ag.add_argument("--csv", metavar="FILE", help="export results to CSV file")
    ag.add_argument("--pdf", metavar="FILE", help="export results to PDF file (requires reportlab)")
    ag.add_argument("--json", metavar="FILE", help="export results to JSON file")
    ag.add_argument("--install", action="store_true", help="prompt to install selected packages via chosen package manager")
    ag.add_argument("--manager", choices=("npm", "pnpm", "yarn", "bun"), default="npm", help="package manager for installation")
    ag.add_argument("--global","-g", dest="global_install", action="store_true", help="perform a global installation")
    ag.add_argument("--dev", action="store_true", help="add as a dev dependency (where supported)")
    ag.add_argument("--dry-run", action="store_true", help="print the install command without executing it")
    args = ag.parse_args()

    if RICH_OK:
        console.print("[green]Searching npm registry…[/green]")
    objs = npm_search(args.query, size=args.size)
    if not objs:
        if RICH_OK:
            console.print("[red]No matches.[/red]")
        else:
            print("No matches.", file=sys.stderr)
        sys.exit(1)

    # Enrich in parallel
    if RICH_OK:
        console.print("[green]Gathering metadata and download stats…[/green]")
    records: list[NpmPkg] = []
    with ThreadPoolExecutor(max_workers=args.threads) as ex:
        futs = [ex.submit(normalize_row, obj) for obj in objs]
        for fut in as_completed(futs):
            row = fut.result()
            if row:
                records.append(row)

    # Sort & trim
    if args.sort == "latest":
        records.sort(key=lambda p: p.released, reverse=True)
    elif args.sort == "downloads":
        records.sort(key=lambda p: p.downloads, reverse=True)
    else:
        records.sort(key=lambda p: p.score, reverse=True)
    records = records[: args.limit]

    # Display
    if RICH_OK:
        table = Table(title=f"npm search: “{args.query}”")
        table.add_column("#", justify="right")
        table.add_column("Package")
        table.add_column("Version", justify="center")
        table.add_column("Released (UTC)", justify="center")
        table.add_column("30-day DLs", justify="right")
        table.add_column("Score", justify="right")
        table.add_column("Summary")
        for idx, p in enumerate(records, 1):
            table.add_row(
                str(idx),
                f"[bold]{p.name}[/]",
                p.version,
                p.released.strftime("%Y-%m-%d"),
                f"{p.downloads:,}",
                f"{p.score:.3f}",
                p.description,
            )
        console.print(table)
    else:
        print(f"npm search: \"{args.query}\"")
        for idx, p in enumerate(records, 1):
            print(f"{idx:>3}. {p.name:30} {p.version:12} {p.released.strftime('%Y-%m-%d')} DL30={p.downloads:>8} score={p.score:.3f}  {p.description}")

    # Exports
    if args.csv:
        write_csv(args.csv, records)
        if RICH_OK:
            console.print(f"[green]CSV saved →[/green] {args.csv}")
        else:
            print(f"CSV saved → {args.csv}")
    if args.json:
        write_json(args.json, records)
        if RICH_OK:
            console.print(f"[green]JSON saved →[/green] {args.json}")
        else:
            print(f"JSON saved → {args.json}")
    if args.pdf:
        try:
            write_pdf(args.pdf, args.query, args.sort, records)
            if RICH_OK:
                console.print(f"[green]PDF saved →[/green] {args.pdf}")
            else:
                print(f"PDF saved → {args.pdf}")
        except RuntimeError as e:
            if RICH_OK:
                console.print(f"[red]PDF not written:[/red] {e}")
            else:
                print(f"PDF not written: {e}", file=sys.stderr)

    # Install step
    if args.install:
        try:
            selection = input("Enter package numbers to install (e.g. 1 2 5 10-12): ").strip()
            chosen = parse_selection(selection, max_index=len(records))
            to_install = [records[i-1].name for i in chosen]
            if not to_install:
                if RICH_OK:
                    console.print("[yellow]No packages selected. Nothing to install.[/]")
                else:
                    print("No packages selected. Nothing to install.")
                return
            cmd = build_install_cmd(args.manager, to_install, getattr(args, "global"), args.dev)
            if args.dry_run:
                if RICH_OK:
                    console.print(f"[cyan]DRY RUN:[/] {cmd_str}")
                else:
                    print("DRY RUN:", cmd_str)
                return
            if RICH_OK:
                console.print(f"Installing via {args.manager}: {', '.join(to_install)}")
            subprocess.run(cmd, check=True)
        except Exception as ex:
            if RICH_OK:
                console.print(f"[red]Installation aborted: {ex}[/red]")
            else:
                print(f"Installation aborted: {ex}", file=sys.stderr)

if __name__ == "__main__":
    main()

