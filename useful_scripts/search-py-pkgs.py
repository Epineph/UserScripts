#!/usr/bin/env python3
"""
Search PyPI, rank matches, optionally map to conda-forge names, export results, and install selected packages.

Usage examples
--------------
# Search for 'pywright', show top 20 by downloads, then prompt to install selected packages
./python-search pywright --sort downloads --limit 20 --install

# Same query without install step
./python-search pywright --sort downloads --limit 20

# Export to CSV and PDF, map to conda-forge names
./python-search neuro --sort latest --with-conda --csv neuro.csv --pdf neuro.pdf
"""
import argparse
import csv
import html
import json
import pathlib
import re
import subprocess
import sys
import time
from collections import namedtuple
from datetime import datetime, timezone

import requests
from dateutil.parser import isoparse
from rapidfuzz import fuzz, process
from rich.console import Console
from rich.table import Table

# --------------------------------------------------------------------- #
# Constants & endpoints                                                 #
# --------------------------------------------------------------------- #
SIMPLE_URL = "https://pypi.org/simple/"
JSON_URL = "https://pypi.org/pypi/{name}/json"
STATS_URL = "https://pypistats.org/api/packages/{name}/recent"

CONDA_SUBDIRS = ("noarch", "linux-64")
CONDA_TMPL = "https://conda.anaconda.org/conda-forge/{subdir}/current_repodata.json"
CACHE_DIR = pathlib.Path.home() / ".cache" / "pypi_rank"
CACHE_DIR.mkdir(parents=True, exist_ok=True)
CONDA_CACHE = CACHE_DIR / "conda_names.json"
CONDA_STALE = 24 * 3600  # seconds

console = Console()
PKG = namedtuple("PKG", "name summary released downloads conda")

# --------------------------------------------------------------------- #
# Utility: parse user selection string into list of indices             #
# --------------------------------------------------------------------- #
def parse_selection(selection: str, max_index: int) -> list[int]:
    """
    Parse a string like "1 2 5 10-12" into a sorted list of unique indices.
    Raises ValueError if any token is invalid or out of range.
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

# --------------------------------------------------------------------- #
# PyPI helpers                                                          #
# --------------------------------------------------------------------- #
def fetch_pypi_index() -> list[str]:
    r = requests.get(SIMPLE_URL, timeout=20)
    r.raise_for_status()
    return [html.unescape(n) for n in
            re.findall(r'<a href="/simple/[^\"]+">([^<]+)</a>', r.text, re.I)]


def best_pypi_matches(query: str, candidates: list[str], k: int = 400) -> list[str]:
    scored = process.extract(query, candidates, scorer=fuzz.QRatio, limit=k)
    return [n for n, s, _ in scored if s >= 30]


def pypi_meta(name: str) -> PKG | None:
    try:
        meta = requests.get(JSON_URL.format(name=name), timeout=15).json()
        info = meta["info"]
        dates = [isoparse(f["upload_time_iso_8601"])
                 for files in meta["releases"].values() for f in files]
        latest = max(dates) if dates else datetime(1970, 1, 1, tzinfo=timezone.utc)
        stats = requests.get(STATS_URL.format(name=name), timeout=15).json()
        dl30 = stats.get("data", {}).get("last_month", 0)
        return PKG(name, info.get("summary", "")[:60], latest, dl30, "")
    except Exception:
        return None

# --------------------------------------------------------------------- #
# conda-forge helpers                                                   #
# --------------------------------------------------------------------- #
def _download_conda_names() -> set[str]:
    names: set[str] = set()
    for sub in CONDA_SUBDIRS:
        try:
            data = requests.get(CONDA_TMPL.format(subdir=sub), timeout=40).json()
            pkgs = data.get("packages", {})
            names.update(meta["name"] for meta in pkgs.values())
        except Exception:
            continue
    return names


def load_conda_names() -> set[str]:
    if CONDA_CACHE.exists() and time.time() - CONDA_CACHE.stat().st_mtime < CONDA_STALE:
        try:
            return set(json.loads(CONDA_CACHE.read_text()))
        except Exception:
            pass
    names = _download_conda_names()
    try:
        CONDA_CACHE.write_text(json.dumps(sorted(names)))
    except Exception:
        pass
    return names


def map_to_conda(pip_name: str, conda_names: set[str]) -> str:
    canon = lambda s: s.lower().replace("_", "-")
    pip_c = canon(pip_name)
    if pip_c in conda_names:
        return pip_c
    match = process.extractOne(pip_c, conda_names, scorer=fuzz.QRatio)
    return match[0] if match and match[1] >= 80 else ""

# --------------------------------------------------------------------- #
# CSV / PDF writers                                                     #
# --------------------------------------------------------------------- #
def write_csv(path: str, records: list[PKG]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["rank", "package", "conda_name",
                    "released_utc", "downloads_30d", "summary"])
        for r, p in enumerate(records, 1):
            w.writerow([r, p.name, p.conda,
                        p.released.strftime("%Y-%m-%d"), p.downloads, p.summary])


def write_pdf(path: str, query: str, criterion: str, records: list[PKG]) -> None:
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
    cvs.drawString(margin, PAGE_H-margin,
                   f"PyPI search: “{query}”  (sorted by {criterion})")
    cvs.setFont("Helvetica", fs)
    y = PAGE_H-margin-1.4*lh
    hdr = ["#", "Package", "micromamba", "Released", "30-day DLs", "Summary"]
    col = [margin, margin+0.5*inch, margin+2.7*inch,
           margin+4.0*inch, margin+5.2*inch, margin+6.4*inch]
    for x, h in zip(col, hdr):
        cvs.drawString(x, y, h)
    y -= lh
    cvs.line(margin, y+2, PAGE_W-margin, y+2)
    for r, p in enumerate(records, 1):
        if r > max_rows:
            break
        cvs.drawString(col[0], y, str(r))
        cvs.drawString(col[1], y, p.name)
        cvs.drawString(col[2], y, p.conda or "—")
        cvs.drawString(col[3], y, p.released.strftime("%Y-%m-%d"))
        cvs.drawRightString(col[4]+0.6*inch, y, f"{p.downloads:,}")
        cvs.drawString(col[5], y, p.summary[:80])
        y -= lh
    cvs.save()

# --------------------------------------------------------------------- #
# Main                                                                  #
# --------------------------------------------------------------------- #
def main() -> None:
    ag = argparse.ArgumentParser(
        description="Search PyPI, rank matches, and install selected packages.")
    ag.add_argument("query", help="search term for PyPI packages")
    ag.add_argument("--sort", choices=("latest", "downloads"), default="latest",
                    help="sorting criterion for results")
    ag.add_argument("--limit", type=int, default=20,
                    help="maximum number of packages to display")
    ag.add_argument("--threads", type=int, default=16,
                    help="number of parallel threads for metadata fetch")
    ag.add_argument("--with-conda", action="store_true",
                    help="map to conda-forge names for micromamba")
    ag.add_argument("--csv", metavar="FILE",
                    help="export results to CSV file")
    ag.add_argument("--pdf", metavar="FILE",
                    help="export results to PDF file (requires reportlab)")
    ag.add_argument("--install", action="store_true",
                    help="prompt to install selected packages via pip")
    args = ag.parse_args()

    console.status("[green bold]Fetching PyPI index…")
    all_pkgs = fetch_pypi_index()
    candidates = best_pypi_matches(args.query, all_pkgs, k=600)

    console.status("[green bold]Downloading per-package metadata…")
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=args.threads) as executor:
        rows = list(filter(None, executor.map(pypi_meta, candidates)))

    # Optional conda mapping
    if args.with_conda:
        console.status("[green bold]Loading conda-forge names…")
        conda_names = load_conda_names()
        rows = [p._replace(conda=map_to_conda(p.name, conda_names)) for p in rows]

    # Sort and trim
    rows.sort(key=(lambda p: p.released) if args.sort == "latest"
              else (lambda p: p.downloads), reverse=True)
    rows = rows[: args.limit]

    if not rows:
        console.print("[red]No matches.[/red]")
        sys.exit(1)

    # Display table
    table = Table(title=f"PyPI search: “{args.query}”")
    table.add_column("#", justify="right")
    table.add_column("Package")
    if args.with_conda:
        table.add_column("micromamba", style="cyan")
    table.add_column("Released (UTC)", justify="center")
    table.add_column("30-day DLs", justify="right")
    table.add_column("Summary")

    for idx, pkg in enumerate(rows, 1):
        cells = [str(idx), f"[bold]{pkg.name}[/]"]
        if args.with_conda:
            cells.append(pkg.conda or "—")
        cells.extend([pkg.released.strftime("%Y-%m-%d"), f"{pkg.downloads:,}", pkg.summary])
        table.add_row(*cells)
    console.print(table)

    # Export if requested
    if args.csv:
        write_csv(args.csv, rows)
        console.print(f"[green]CSV saved →[/green] {args.csv}")
    if args.pdf:
        try:
            write_pdf(args.pdf, args.query, args.sort, rows)
            console.print(f"[green]PDF saved →[/green] {args.pdf}")
        except RuntimeError as e:
            console.print(f"[red]PDF not written:[/red] {e}")

    # Prompt installation
    if args.install:
        prompt = ("Enter package numbers to install (e.g. 1 2 5 10-12): ")
        try:
            selection = input(prompt)
            chosen = parse_selection(selection, max_index=len(rows))
            to_install = [rows[i-1].name for i in chosen]
            if to_install:
                console.print(f"Installing: {', '.join(to_install)}")
                subprocess.run([sys.executable, "-m", "pip", "install", *to_install], check=True)
            else:
                console.print("[yellow]No packages selected. Nothing to install.[/]")
        except Exception as ex:
            console.print(f"[red]Installation aborted: {ex}[/red]")

if __name__ == "__main__":
    main()

