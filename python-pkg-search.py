#!/usr/bin/env python3
# ──────────────────────────────────────────────────────────────────────────────
# python-search — Search PyPI or list Top PyPI packages, rank, export, install
# ──────────────────────────────────────────────────────────────────────────────
"""
Search PyPI, rank matches, optionally map to conda-forge names, export results,
and install selected packages.

New features
------------
- Omit the query to browse the global "Top PyPI packages" (updated monthly).
- Filter by recency: keep only projects released within N days.
- Choose downloads window when fetching stats: day/week/month.

Usage examples
--------------
# 1) Top 300 by downloads (no query), map to conda, export CSV
./python-search --limit 300 --with-conda --csv top300.csv

# 2) Top 300 restricted to fresh releases in the last 90 days
./python-search --limit 300 --released-since 90

# 3) Query 'pywright', show top 20 by downloads (last week)
./python-search pywright --sort downloads --recent week --limit 20

# 4) Query 'neuro', sort by latest, export CSV/PDF, and install picked ones
./python-search neuro --sort latest --with-conda \
  --csv neuro.csv --pdf neuro.pdf --install
"""
from __future__ import annotations

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
from datetime import datetime, timedelta, timezone
from typing import Iterable

import requests
from dateutil.parser import isoparse
from rapidfuzz import fuzz, process
from rich.console import Console
from rich.table import Table

# ──────────────────────────────────────────────────────────────────────────────
# Constants & endpoints
# ──────────────────────────────────────────────────────────────────────────────
SIMPLE_URL = "https://pypi.org/simple/"
JSON_URL = "https://pypi.org/pypi/{name}/json"
STATS_URL = "https://pypistats.org/api/packages/{name}/recent"
# Monthly dump of ~15k most-downloaded packages (project, download_count, ...)
# (Fallback keeps the historical 30-days path if needed.)
TOP_URLS = (
    "https://hugovk.github.io/top-pypi-packages/top-pypi-packages.min.json",
    "https://hugovk.github.io/top-pypi-packages/top-pypi-packages-30-days.min.json",
)

CONDA_SUBDIRS = ("noarch", "linux-64")
CONDA_TMPL = "https://conda.anaconda.org/conda-forge/{subdir}/current_repodata.json"

CACHE_DIR = pathlib.Path.home() / ".cache" / "pypi_rank"
CACHE_DIR.mkdir(parents=True, exist_ok=True)
CONDA_CACHE = CACHE_DIR / "conda_names.json"
TOP_CACHE = CACHE_DIR / "top_pypi.json"
CONDA_STALE = 24 * 3600  # seconds
TOP_STALE = 24 * 3600  # seconds

console = Console()
PKG = namedtuple("PKG", "name summary released downloads conda")


# ──────────────────────────────────────────────────────────────────────────────
# Utility: parse user selection string into list of indices
# ──────────────────────────────────────────────────────────────────────────────
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
                raise ValueError(
                    f"Range '{token}' out of valid bounds 1-{max_index}")
            indices.update(range(start, end + 1))
        elif token.isdigit():
            idx = int(token)
            if idx < 1 or idx > max_index:
                raise ValueError(
                    f"Index '{idx}' out of valid bounds 1-{max_index}")
            indices.add(idx)
        else:
            raise ValueError(f"Invalid token: '{token}'")
    return sorted(indices)


# ──────────────────────────────────────────────────────────────────────────────
# PyPI helpers
# ──────────────────────────────────────────────────────────────────────────────
def fetch_pypi_index() -> list[str]:
    r = requests.get(SIMPLE_URL, timeout=20)
    r.raise_for_status()
    return [
        html.unescape(n) for n in re.findall(
            r'<a href="/simple/[^\"]+">([^<]+)</a>', r.text, re.I)
    ]


def best_pypi_matches(query: str,
                      candidates: list[str],
                      k: int = 400) -> list[str]:
    scored = process.extract(query, candidates, scorer=fuzz.QRatio, limit=k)
    return [n for n, s, _ in scored if s >= 30]


def pypi_meta(name: str,
              recent_key: str = "last_month",
              override_downloads: int | None = None) -> PKG | None:
    """
  Fetch summary, latest release timestamp, and downloads (recent_key).
  If override_downloads is given, skip the stats call and use that value.
  """
    try:
        meta = requests.get(JSON_URL.format(name=name), timeout=15).json()
        info = meta["info"]
        dates = [
            isoparse(f["upload_time_iso_8601"])
            for files in meta["releases"].values() for f in files
        ]
        latest = max(dates) if dates else datetime(
            1970, 1, 1, tzinfo=timezone.utc)
        if override_downloads is None:
            stats = requests.get(STATS_URL.format(name=name),
                                 timeout=15).json()
            dl = stats.get("data", {}).get(recent_key, 0)
        else:
            dl = int(override_downloads)
        return PKG(name, info.get("summary", "")[:60], latest, dl, "")
    except Exception:
        return None


# ──────────────────────────────────────────────────────────────────────────────
# Top PyPI packages helpers (monthly dump)
# ──────────────────────────────────────────────────────────────────────────────
def _download_top_dump() -> dict:
    last_err = None
    for url in TOP_URLS:
        try:
            r = requests.get(url, timeout=30)
            r.raise_for_status()
            return r.json()
        except Exception as ex:
            last_err = ex
            continue
    raise RuntimeError(f"Failed to fetch Top PyPI dump: {last_err}")


def load_top_dump() -> dict:
    if TOP_CACHE.exists(
    ) and time.time() - TOP_CACHE.stat().st_mtime < TOP_STALE:
        try:
            return json.loads(TOP_CACHE.read_text())
        except Exception:
            pass
    data = _download_top_dump()
    try:
        TOP_CACHE.write_text(json.dumps(data))
    except Exception:
        pass
    return data


def iter_top_rows(doc: dict) -> Iterable[tuple[str, int]]:
    """
  Yield (project, downloads) from known variants of the dump.
  """
    rows = doc.get("rows") or doc.get("data") or doc.get("projects") or []
    for row in rows:
        name = row.get("project") or row.get("package") or row.get("name")
        dls = (row.get("download_count") or row.get("downloads")
               or row.get("count") or 0)
        if name:
            yield name, int(dls)


# ──────────────────────────────────────────────────────────────────────────────
# conda-forge helpers
# ──────────────────────────────────────────────────────────────────────────────
def _download_conda_names() -> set[str]:
    names: set[str] = set()
    for sub in CONDA_SUBDIRS:
        try:
            data = requests.get(CONDA_TMPL.format(subdir=sub),
                                timeout=40).json()
            pkgs = data.get("packages", {})
            names.update(meta["name"] for meta in pkgs.values())
        except Exception:
            continue
    return names


def load_conda_names() -> set[str]:
    if CONDA_CACHE.exists(
    ) and time.time() - CONDA_CACHE.stat().st_mtime < CONDA_STALE:
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


# ──────────────────────────────────────────────────────────────────────────────
# CSV / PDF writers
# ──────────────────────────────────────────────────────────────────────────────
def write_csv(path: str, records: list[PKG]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow([
            "rank", "package", "conda_name", "released_utc",
            "downloads_window", "summary"
        ])
        for r, p in enumerate(records, 1):
            w.writerow([
                r, p.name, p.conda,
                p.released.strftime("%Y-%m-%d"), p.downloads, p.summary
            ])


def write_pdf(path: str, title: str, criterion: str,
              records: list[PKG]) -> None:
    try:
        from reportlab.lib.pagesizes import letter
        from reportlab.lib.units import inch
        from reportlab.pdfgen.canvas import Canvas
    except ModuleNotFoundError:
        raise RuntimeError("python-reportlab missing.")
    PAGE_W, PAGE_H = letter
    margin, lh, fs = 0.6 * inch, 0.22 * inch, 9
    max_rows = int((PAGE_H - 2 * margin - 1.6 * lh) // lh)
    cvs = Canvas(path, pagesize=letter)
    cvs.setFont("Helvetica-Bold", 12)
    cvs.drawString(margin, PAGE_H - margin,
                   f"{title}  (sorted by {criterion})")
    cvs.setFont("Helvetica", fs)
    y = PAGE_H - margin - 1.4 * lh
    hdr = ["#", "Package", "micromamba", "Released", "DLs", "Summary"]
    col = [
        margin, margin + 0.5 * inch, margin + 2.7 * inch, margin + 4.0 * inch,
        margin + 5.2 * inch, margin + 6.2 * inch
    ]
    for x, h in zip(col, hdr):
        cvs.drawString(x, y, h)
    y -= lh
    cvs.line(margin, y + 2, PAGE_W - margin, y + 2)
    for r, p in enumerate(records, 1):
        if r > max_rows:
            break
        cvs.drawString(col[0], y, str(r))
        cvs.drawString(col[1], y, p.name)
        cvs.drawString(col[2], y, p.conda or "—")
        cvs.drawString(col[3], y, p.released.strftime("%Y-%m-%d"))
        cvs.drawRightString(col[4] + 0.6 * inch, y, f"{p.downloads:,}")
        cvs.drawString(col[5], y, p.summary[:80])
        y -= lh
    cvs.save()


# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
def main() -> None:
    ag = argparse.ArgumentParser(description=(
        "Search PyPI or list Top PyPI packages, then rank, export, "
        "and optionally install selected packages."))
    ag.add_argument("query", nargs="?", help="search term; omit to browse Top")
    ag.add_argument("--sort",
                    choices=("latest", "downloads"),
                    default="latest",
                    help="sorting criterion for results")
    ag.add_argument("--limit",
                    type=int,
                    default=20,
                    help="maximum number of packages to display")
    ag.add_argument("--recent",
                    choices=("day", "week", "month"),
                    default="month",
                    help="downloads window used from PyPI Stats")
    ag.add_argument("--released-since",
                    type=int,
                    metavar="DAYS",
                    help="only keep packages with a release in the last DAYS")
    ag.add_argument("--threads",
                    type=int,
                    default=16,
                    help="max parallel threads for metadata fetch")
    ag.add_argument("--with-conda",
                    action="store_true",
                    help="map to conda-forge names for micromamba")
    ag.add_argument("--csv", metavar="FILE", help="export results to CSV file")
    ag.add_argument("--pdf",
                    metavar="FILE",
                    help="export results to PDF file (requires reportlab)")
    ag.add_argument("--install",
                    action="store_true",
                    help="prompt to install selected packages via pip")
    args = ag.parse_args()

    recent_map = {
        "day": "last_day",
        "week": "last_week",
        "month": "last_month"
    }
    recent_key = recent_map[args.recent]

    # Decide mode: query vs. Top list
    if args.query:
        with console.status("[green bold]Fetching PyPI index…"):
            all_pkgs = fetch_pypi_index()
            candidates = best_pypi_matches(args.query, all_pkgs, k=600)
        with console.status("[green bold]Downloading per-package metadata…"):
            from concurrent.futures import ThreadPoolExecutor
            with ThreadPoolExecutor(max_workers=args.threads) as ex:
                rows = list(
                    filter(
                        None,
                        ex.map(lambda n: pypi_meta(n, recent_key=recent_key),
                               candidates)))
        title = f"PyPI search: “{args.query}”"
    else:
        with console.status("[green bold]Loading Top PyPI packages…"):
            doc = load_top_dump()
            top_pairs = list(iter_top_rows(doc))
            # Already sorted by downloads in the dump; we still cap to a soft bound.
            # We fetch metadata only for the first N*1.5 to allow post-filters.
            pre_cap = max(args.limit, 1) * 3 // 2
            top_pairs = top_pairs[:max(pre_cap, args.limit)]
        with console.status("[green bold]Fetching metadata for Top packages…"):
            from concurrent.futures import ThreadPoolExecutor
            with ThreadPoolExecutor(max_workers=args.threads) as ex:
                rows = list(
                    filter(
                        None,
                        ex.map(
                            lambda tup: pypi_meta(tup[0],
                                                  recent_key=recent_key,
                                                  override_downloads=tup[1]),
                            top_pairs)))
        title = "Top PyPI packages (monthly dump)"

    # Optional conda mapping
    if args.with_conda and rows:
        with console.status("[green bold]Loading conda-forge names…"):
            conda_names = load_conda_names()
        rows = [
            p._replace(conda=map_to_conda(p.name, conda_names)) for p in rows
        ]

    # Optional recency filter (by latest release date)
    if args.released - since is not None:  # dashed name not valid in code; see below
        pass
