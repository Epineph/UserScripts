#!/usr/bin/env python3
# ──────────────────────────────────────────────────────────────────────────────
# python-search — Search PyPI or list Top PyPI packages, rank, export, install
# ──────────────────────────────────────────────────────────────────────────────
"""
Search PyPI, rank matches, optionally map to conda-forge names, export results,
and install selected packages.

Highlights
----------
- Omit the query to browse Top PyPI Packages (monthly dump).
- By default, downloads come from the Top-PyPI dump (fast, reliable).
- Optional PyPIStats lookups for {day, week, month} after filtering.
- Filter by latest release recency: --released-since DAYS.

Usage examples
--------------
# Top 300 by downloads (no query), map to conda, export CSV
./python-search --limit 300 --with-conda --csv top300.csv

# Top 300 but keep only projects with a release in last 90 days
./python-search --limit 300 --released-since 90

# Query 'pywright', show top 20 by downloads (using Top dump)
./python-search pywright --sort downloads --limit 20

# Same, but compute downloads via PyPIStats "last_week" (slower)
./python-search pywright --sort downloads --downloads-source pypistats \
  --recent week --limit 20

# Query 'neuro', sort by latest, export CSV/PDF, and optionally install
./python-search neuro --sort latest --with-conda --csv neuro.csv \
  --pdf neuro.pdf --install
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
SIMPLE_URL   = "https://pypi.org/simple/"
JSON_URL     = "https://pypi.org/pypi/{name}/json"
PSTAT_URL    = "https://pypistats.org/api/packages/{name}/recent"

# Top PyPI monthly dump (~15k most-downloaded). We keep 30d variant as fallback.
TOP_URLS = (
  "https://hugovk.github.io/top-pypi-packages/top-pypi-packages.min.json",
  "https://hugovk.github.io/top-pypi-packages/top-pypi-packages-30-days.min.json",
)

CONDA_SUBDIRS = ("noarch", "linux-64")
CONDA_TMPL    = "https://conda.anaconda.org/conda-forge/{subdir}/current_repodata.json"

CACHE_DIR   = pathlib.Path.home() / ".cache" / "pypi_rank"
CACHE_DIR.mkdir(parents=True, exist_ok=True)
CONDA_CACHE = CACHE_DIR / "conda_names.json"
TOP_CACHE   = CACHE_DIR / "top_pypi.json"

# cache staleness (seconds)
CONDA_STALE = 24 * 3600
TOP_STALE   = 24 * 3600

console = Console()
PKG = namedtuple("PKG", "name summary released downloads conda")

# ──────────────────────────────────────────────────────────────────────────────
# Small HTTP helpers
# ──────────────────────────────────────────────────────────────────────────────
def get_json(url: str, timeout: float = 20.0, tries: int = 2) -> dict:
  last = None
  for _ in range(max(1, tries)):
    try:
      r = requests.get(url, timeout=timeout,
                       headers={"User-Agent": "python-search/1.0"})
      r.raise_for_status()
      return r.json()
    except Exception as ex:
      last = ex
      time.sleep(0.4)
  raise RuntimeError(f"GET {url} failed: {last}")

# ──────────────────────────────────────────────────────────────────────────────
# Selection parser
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
        raise ValueError(f"Range '{token}' out of bounds 1-{max_index}")
      indices.update(range(start, end + 1))
    elif token.isdigit():
      idx = int(token)
      if idx < 1 or idx > max_index:
        raise ValueError(f"Index '{idx}' out of bounds 1-{max_index}")
      indices.add(idx)
    else:
      raise ValueError(f"Invalid token: '{token}'")
  return sorted(indices)

# ──────────────────────────────────────────────────────────────────────────────
# PyPI index + metadata
# ──────────────────────────────────────────────────────────────────────────────
def fetch_pypi_index() -> list[str]:
  r = requests.get(SIMPLE_URL, timeout=30)
  r.raise_for_status()
  return [html.unescape(n) for n in
          re.findall(r'<a href="/simple/[^\"]+">([^<]+)</a>', r.text, re.I)]

def best_pypi_matches(query: str, candidates: list[str], k: int = 400) -> list[str]:
  scored = process.extract(query, candidates, scorer=fuzz.QRatio, limit=k)
  return [n for n, s, _ in scored if s >= 30]

def pypi_meta(name: str) -> PKG | None:
  """
  Summary + latest release timestamp. Downloads are filled later.
  """
  try:
    meta = get_json(JSON_URL.format(name=name), timeout=15, tries=2)
    info = meta.get("info", {})
    releases = meta.get("releases", {}) or {}
    dates = []
    for files in releases.values():
      for f in files or []:
        ts = f.get("upload_time_iso_8601")
        if ts:
          try:
            dates.append(isoparse(ts))
          except Exception:
            pass
    latest = max(dates) if dates else datetime(1970, 1, 1, tzinfo=timezone.utc)
    return PKG(name=name,
               summary=(info.get("summary") or "")[:80],
               released=latest,
               downloads=0,
               conda="")
  except Exception:
    return None)

# ──────────────────────────────────────────────────────────────────────────────
# Top PyPI dump helpers
# ──────────────────────────────────────────────────────────────────────────────
def _download_top_dump() -> dict:
  last_err = None
  for url in TOP_URLS:
    try:
      return get_json(url, timeout=30, tries=2)
    except Exception as ex:
      last_err = ex
  raise RuntimeError(f"Top-PyPI dump fetch failed: {last_err}")

def load_top_dump() -> dict:
  if TOP_CACHE.exists() and time.time() - TOP_CACHE.stat().st_mtime < TOP_STALE:
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

def top_dump_to_map(doc: dict) -> dict[str, int]:
  """
  Normalize multiple historical schemas → {lower_name: downloads}
  """
  rows = doc.get("rows") or doc.get("data") or doc.get("projects") or []
  out: dict[str, int] = {}
  for row in rows:
    name = (row.get("project") or row.get("package") or row.get("name"))
    dls  = (row.get("download_count") or row.get("downloads") or
            row.get("count") or 0)
    if name:
      out[name.lower()] = int(dls)
  return out

# ──────────────────────────────────────────────────────────────────────────────
# PyPIStats (optional, minimized calls)
# ──────────────────────────────────────────────────────────────────────────────
def pypistats_downloads(names: list[str], recent_key: str,
                        threads: int = 8) -> dict[str, int]:
  """
  Fetch {name: downloads_recent_key} for a small set of names.
  Designed for <= few hundred calls. Returns 0 on failures.
  """
  from concurrent.futures import ThreadPoolExecutor, as_completed
  recent_key = recent_key  # 'last_day' | 'last_week' | 'last_month'
  res: dict[str, int] = {}
  def task(n: str) -> tuple[str, int]:
    try:
      data = get_json(PSTAT_URL.format(name=n), timeout=12, tries=2)
      return (n, int(data.get("data", {}).get(recent_key, 0)))
    except Exception:
      return (n, 0)
  with ThreadPoolExecutor(max_workers=max(1, threads)) as ex:
    futs = {ex.submit(task, n): n for n in names}
    for f in as_completed(futs):
      n, v = f.result()
      res[n] = v
  return res

# ──────────────────────────────────────────────────────────────────────────────
# conda-forge helpers
# ──────────────────────────────────────────────────────────────────────────────
def _download_conda_names() -> set[str]:
  names: set[str] = set()
  for sub in CONDA_SUBDIRS:
    try:
      data = get_json(CONDA_TMPL.format(subdir=sub), timeout=40, tries=2)
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

# ──────────────────────────────────────────────────────────────────────────────
# CSV / PDF writers
# ──────────────────────────────────────────────────────────────────────────────
def write_csv(path: str, records: list[PKG]) -> None:
  with open(path, "w", newline="", encoding="utf-8") as fh:
    w = csv.writer(fh)
    w.writerow(["rank", "package", "conda_name",
                "released_utc", "downloads", "summary"])
    for r, p in enumerate(records, 1):
      w.writerow([r, p.name, p.conda,
                  p.released.strftime("%Y-%m-%d"), p.downloads, p.summary])

def write_pdf(path: str, title: str, criterion: str, records: list[PKG]) -> None:
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
  cvs.drawString(margin, PAGE_H-margin, f"{title}  (sorted by {criterion})")
  cvs.setFont("Helvetica", fs)
  y = PAGE_H-margin-1.4*lh
  hdr = ["#", "Package", "micromamba", "Released", "DLs", "Summary"]
  col = [margin, margin+0.5*inch, margin+2.7*inch,
         margin+4.0*inch, margin+5.2*inch, margin+6.2*inch]
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

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
def main() -> None:
  ag = argparse.ArgumentParser(
    description=("Search PyPI or list Top PyPI packages, then rank, export, "
                 "and optionally install selected packages."),
    formatter_class=argparse.ArgumentDefaultsHelpFormatter,
  )
  ag.add_argument("query", nargs="?", help="search term; omit to browse Top")
  ag.add_argument("--sort", choices=("latest", "downloads"), default="latest",
                  help="sorting criterion for results")
  ag.add_argument("--limit", type=int, default=20,
                  help="maximum number of packages to display")
  ag.add_argument("--max-candidates", type=int, default=300,
                  help="cap fuzzy matches (controls network/CPU)")
  ag.add_argument("--downloads-source",
                  choices=("dump", "pypistats"), default="dump",
                  help="where to obtain download counts")
  ag.add_argument("--recent", choices=("day", "week", "month"), default="month",
                  help="PyPIStats window (if downloads-source=pypistats)")
  ag.add_argument("--released-since", type=int, metavar="DAYS",
                  help="only keep packages with a release in last DAYS")
  ag.add_argument("--threads", type=int, default=12,
                  help="max parallel threads for metadata fetch")
  ag.add_argument("--with-conda", action="store_true",
                  help="map to conda-forge names for micromamba")
  ag.add_argument("--csv", metavar="FILE", help="export results to CSV file")
  ag.add_argument("--pdf", metavar="FILE",
                  help="export results to PDF (requires reportlab)")
  ag.add_argument("--install", action="store_true",
                  help="prompt to install selected packages via pip")
  args = ag.parse_args()

  recent_map = {"day": "last_day", "week": "last_week", "month": "last_month"}
  recent_key = recent_map[args.recent]

  # Decide mode: query vs. Top list
  if args.query:
    with console.status("[green bold]Fetching PyPI index…"):
      try:
        all_pkgs = fetch_pypi_index()
      except Exception as ex:
        console.print(f"[red]Index fetch failed:[/red] {ex}")
        sys.exit(2)
      candidates = best_pypi_matches(args.query, all_pkgs, k=args.max_candidates)
      if not candidates:
        console.print("[red]No candidates from fuzzy search.[/red]")
        sys.exit(1)

    with console.status("[green bold]Downloading metadata…"):
      from concurrent.futures import ThreadPoolExecutor
      with ThreadPoolExecutor(max_workers=max(1, args.threads)) as ex:
        rows = list(filter(None, ex.map(pypi_meta, candidates)))
    title = f"PyPI search: “{args.query}”"

  else:
    with console.status("[green bold]Loading Top PyPI dump…"):
      try:
        doc = load_top_dump()
      except Exception as ex:
        console.print(f"[red]Top dump failed:[/red] {ex}")
        sys.exit(2)
      top_map = top_dump_to_map(doc)
      # Keep only top N*1.5 to allow for recency filters; clamp below for safety
      names = list(top_map.keys())[: max(args.limit * 2, args.limit)]
    with console.status("[green bold]Fetching metadata for Top packages…"):
      from concurrent.futures import ThreadPoolExecutor
      with ThreadPoolExecutor(max_workers=max(1, args.threads)) as ex:
        rows = list(filter(None, ex.map(pypi_meta, names)))
    title = "Top PyPI packages (monthly dump)"

  if not rows:
    console.print("[red]No metadata rows.[/red]")
    sys.exit(1)

  # Optional recency filter (latest release timestamp)
  if args.released_since is not None:
    cutoff = datetime.now(timezone.utc) - timedelta(days=int(args.released_since))
    rows = [p for p in rows if p.released >= cutoff]
    if not rows:
      console.print("[yellow]All rows filtered by recency.[/yellow]")
      sys.exit(0)

  # Attach downloads
  dl_source_used = "dump"
  top_map: dict[str, int] = {}
  if args.downloads_source == "dump":
    try:
      doc = load_top_dump()
      top_map = top_dump_to_map(doc)
    except Exception:
      top_map = {}
    rows = [p._replace(downloads=top_map.get(p.name.lower(), 0)) for p in rows]
  else:
    # pypistats applied only to the set about to be sorted/trimmed
    dl_source_used = f"pypistats:{args.recent}"
    names = [p.name for p in rows]
    dls = pypistats_downloads(names, recent_key=recent_key, threads=min(8, args.threads))
    rows = [p._replace(downloads=dls.get(p.name, 0)) for p in rows]

  # Optional conda mapping
  if args.with_conda:
    with console.status("[green bold]Loading conda-forge names…"):
      conda_names = load_conda_names()
    rows = [p._replace(conda=map_to_conda(p.name, conda_names)) for p in rows]

  # Sort and trim
  if args.sort == "latest":
    rows.sort(key=lambda p: p.released, reverse=True)
  else:
    rows.sort(key=lambda p: p.downloads, reverse=True)
  rows = rows[: args.limit]

  # Display table
  table = Table(title=f"{title}  [dim](DLs: {dl_source_used})[/]")
  table.add_column("#", justify="right")
  table.add_column("Package")
  if args.with_conda:
    table.add_column("micromamba", style="cyan")
  table.add_column("Released (UTC)", justify="center")
  table.add_column("Downloads", justify="right")
  table.add_column("Summary")

  for idx, pkg in enumerate(rows, 1):
    cells = [str(idx), f"[bold]{pkg.name}[/]"]
    if args.with_conda:
      cells.append(pkg.conda or "—")
    cells.extend([pkg.released.strftime("%Y-%m-%d"),
                  f"{pkg.downloads:,}", pkg.summary])
    table.add_row(*cells)
  console.print(table)

  # Export if requested
  if args.csv:
    write_csv(args.csv, rows)
    console.print(f"[green]CSV saved →[/green] {args.csv}")
  if args.pdf:
    try:
      write_pdf(args.pdf, title, args.sort, rows)
      console.print(f"[green]PDF saved →[/green] {args.pdf}")
    except RuntimeError as e:
      console.print(f"[red]PDF not written:[/red] {e}")

  # Prompt installation
  if args.install:
    prompt = "Enter package numbers to install (e.g. 1 2 5 10-12): "
    try:
      selection = input(prompt)
      chosen = parse_selection(selection, max_index=len(rows))
      to_install = [rows[i-1].name for i in chosen]
      if to_install:
        console.print(f"Installing: {', '.join(to_install)}")
        subprocess.run([sys.executable, "-m", "pip", "install", *to_install],
                       check=True)
      else:
        console.print("[yellow]No packages selected. Nothing to install.[/]")
    except Exception as ex:
      console.print(f"[red]Installation aborted: {ex}[/red]")

if __name__ == "__main__":
  main()

