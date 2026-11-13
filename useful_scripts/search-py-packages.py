#!/usr/bin/env python3
"""Search PyPI package names and rank a bounded set of matches.

Requirements
------------
  python -m pip install requests rapidfuzz rich
  python -m pip install reportlab  # only for --pdf

Examples
--------
  search-py-pkgs neuro image --sort downloads --period month
  search-py-pkgs "water maze" --match any --sort relevance
  search-py-pkgs neuroscience --sort newest --since 2026-01-01 \
    --date-field created
  search-py-pkgs tracking --sort updated --with-conda --csv found.csv
  search-py-pkgs microscopy --sort downloads --period week --install

Searches match package *names*. Results are ranked only among the selected
--candidates name matches, not every package on PyPI. Downloads come from
PyPI Stats; its recent API offers day, week, and month, but no lifetime total.
"""

import argparse
import csv
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, replace
from datetime import date, datetime, timezone
from urllib.parse import quote

import requests
from rapidfuzz import fuzz, process
from rich.console import Console
from rich.table import Table
from rich.text import Text


# ---------------------------------------------------------------------------
# Data sources and local cache
# ---------------------------------------------------------------------------
SIMPLE_URL = "https://pypi.org/simple/"
JSON_URL = "https://pypi.org/pypi/{name}/json"
STATS_URL = "https://pypistats.org/api/packages/{name}/recent"
CONDA_URL = ("https://conda.anaconda.org/conda-forge/{subdir}"
             "/current_repodata.json")
USER_AGENT = "search-py-pkgs/2.0 (interactive package search)"
CACHE_DIR = pathlib.Path.home() / ".cache" / "pypi_rank"
DAY = 24 * 60 * 60
CONSOLE = Console()


@dataclass(frozen=True)
class Package:
  name: str
  summary: str
  created: datetime | None
  updated: datetime | None
  downloads: int | None
  relevance: float
  conda: str = ""


def canonical(name: str) -> str:
  """Use the same separator equivalence as PyPI project names."""
  return re.sub(r"[-_.]+", "-", name).lower()


def cache_file(section: str, name: str) -> pathlib.Path:
  return CACHE_DIR / section / f"{canonical(name)}.json"


def read_cache(path: pathlib.Path, max_age: int = DAY):
  try:
    if time.time() - path.stat().st_mtime < max_age:
      return json.loads(path.read_text(encoding="utf-8"))
  except (OSError, ValueError):
    pass
  return None


def write_cache(path: pathlib.Path, data) -> None:
  """Write atomically; a read-only home simply disables caching."""
  temporary = None
  try:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
      mode="w", encoding="utf-8", dir=path.parent,
      prefix=".tmp-", delete=False
    ) as handle:
      temporary = pathlib.Path(handle.name)
      json.dump(data, handle, ensure_ascii=False)
    os.replace(temporary, path)
  except OSError:
    pass
  finally:
    if temporary is not None:
      try:
        temporary.unlink(missing_ok=True)
      except OSError:
        pass


def fetch_json(url: str, timeout: int = 30) -> dict:
  response = requests.get(
    url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
    timeout=(8, timeout)
  )
  response.raise_for_status()
  return response.json()


# ---------------------------------------------------------------------------
# Search by project name
# ---------------------------------------------------------------------------
def fetch_pypi_index() -> list[str]:
  cached = read_cache(cache_file("index", "projects"))
  if isinstance(cached, list):
    return cached

  response = requests.get(
    SIMPLE_URL,
    headers={"User-Agent": USER_AGENT,
             "Accept": "application/vnd.pypi.simple.v1+json"},
    timeout=(8, 90)
  )
  response.raise_for_status()
  names = [entry["name"] for entry in response.json()["projects"]]
  write_cache(cache_file("index", "projects"), names)
  return names


def find_candidates(
  keywords: list[str], names: list[str], match: str, maximum: int
) -> tuple[list[tuple[str, float]], int, bool]:
  """Rank name matches before spending requests on project metadata."""
  terms = [canonical(word) for arg in keywords for word in arg.split()]
  query = "-".join(terms)
  matches = []
  for name in names:
    normalized = canonical(name)
    hits = sum(term in normalized for term in terms)
    if (hits == len(terms) if match == "all" else hits > 0):
      score = fuzz.WRatio(query, normalized)
      matches.append((name, score, hits))

  # Retain useful typo correction for a single keyword from the old script.
  fuzzy_fallback = False
  if not matches and len(terms) == 1:
    fuzzy_fallback = True
    suggestions = process.extract(
      query, names, scorer=fuzz.WRatio, processor=canonical,
      score_cutoff=70, limit=maximum
    )
    matches = [(name, score, 0) for name, score, _ in suggestions]

  matches.sort(key=lambda row: (-row[2], -row[1], len(row[0]),
                                row[0].lower()))
  return ([(name, score) for name, score, _ in matches[:maximum]],
          len(matches), fuzzy_fallback)


# ---------------------------------------------------------------------------
# Project dates and download statistics
# ---------------------------------------------------------------------------
def parse_utc(value: str) -> datetime:
  parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
  return parsed.replace(tzinfo=timezone.utc) if parsed.tzinfo is None \
    else parsed.astimezone(timezone.utc)


def read_project(name: str) -> tuple[str, datetime | None,
                                     datetime | None] | None:
  path = cache_file("projects", name)
  cached = read_cache(path)
  if isinstance(cached, dict) and "summary" in cached:
    try:
      return (cached["summary"],
              parse_utc(cached["created"]) if cached["created"] else None,
              parse_utc(cached["updated"]) if cached["updated"] else None)
    except (KeyError, TypeError, ValueError):
      pass

  try:
    data = fetch_json(JSON_URL.format(name=quote(name, safe="")))
    dates = [parse_utc(file["upload_time_iso_8601"])
             for files in data["releases"].values() for file in files
             if file.get("upload_time_iso_8601")]
    created = min(dates) if dates else None
    updated = max(dates) if dates else None
    summary = (data.get("info", {}).get("summary") or "").strip()
    summary = " ".join(summary.split())
  except (requests.RequestException, ValueError, KeyError, TypeError):
    return None

  write_cache(path, {
    "summary": summary,
    "created": created.isoformat() if created else None,
    "updated": updated.isoformat() if updated else None
  })
  return summary, created, updated


def read_downloads(name: str, period: str) -> int | None:
  path = cache_file("stats", name)
  data = read_cache(path)
  if not isinstance(data, dict):
    try:
      data = fetch_json(STATS_URL.format(name=quote(name, safe="")))
    except (requests.RequestException, ValueError):
      return None
    if isinstance(data, dict) and isinstance(data.get("data"), dict):
      write_cache(path, data)

  if not isinstance(data, dict) or not isinstance(data.get("data"), dict):
    return None
  value = data.get("data", {}).get(f"last_{period}")
  return value if isinstance(value, int) and value >= 0 else None


def package_info(candidate: tuple[str, float], period: str) -> Package | None:
  name, relevance = candidate
  metadata = read_project(name)
  if metadata is None:
    return None
  summary, created, updated = metadata
  downloads = read_downloads(name, period)
  return Package(name, summary, created, updated, downloads, relevance)


# ---------------------------------------------------------------------------
# Optional exact conda-forge mapping
# ---------------------------------------------------------------------------
def load_conda_names() -> dict[str, str]:
  cached = read_cache(cache_file("conda", "names"))
  if isinstance(cached, dict):
    return cached

  mapping = {}
  for subdir in ("noarch", "linux-64"):
    try:
      data = fetch_json(CONDA_URL.format(subdir=subdir), timeout=90)
    except (requests.RequestException, ValueError):
      continue
    for field in ("packages", "packages.conda"):
      for package in data.get(field, {}).values():
        name = package.get("name")
        if name:
          mapping[canonical(name)] = name
  if mapping:
    write_cache(cache_file("conda", "names"), mapping)
  return mapping


# ---------------------------------------------------------------------------
# Sorting and output
# ---------------------------------------------------------------------------
def sort_packages(rows: list[Package], criterion: str) -> list[Package]:
  if criterion == "name":
    return sorted(rows, key=lambda p: p.name.lower())
  if criterion == "downloads":
    return sorted(rows, key=lambda p: (
      p.downloads if p.downloads is not None else -1, p.relevance
    ), reverse=True)
  if criterion in ("newest", "updated", "latest"):
    field = "created" if criterion == "newest" else "updated"
    return sorted(rows, key=lambda p: (
      getattr(p, field) or datetime.min.replace(tzinfo=timezone.utc),
      p.relevance
    ), reverse=True)
  return sorted(rows, key=lambda p: p.relevance, reverse=True)


def date_text(value: datetime | None) -> str:
  return value.strftime("%Y-%m-%d") if value else "—"


def count_text(value: int | None) -> str:
  return f"{value:,}" if value is not None else "—"


def write_csv(path: str, rows: list[Package], period: str) -> None:
  with open(path, "w", newline="", encoding="utf-8") as handle:
    writer = csv.writer(handle)
    writer.writerow(["rank", "package", "conda_name",
                     "first_file_upload_utc", "last_file_upload_utc",
                     f"downloads_last_{period}",
                     "name_relevance", "summary"])
    for rank, pkg in enumerate(rows, 1):
      writer.writerow([rank, pkg.name, pkg.conda,
                       date_text(pkg.created), date_text(pkg.updated),
                       pkg.downloads if pkg.downloads is not None else "",
                       round(pkg.relevance, 2), pkg.summary])


def write_pdf(path: str, query: str, criterion: str, period: str,
              rows: list[Package], with_conda: bool) -> None:
  try:
    from reportlab.lib.pagesizes import letter, landscape
    from reportlab.pdfbase.pdfmetrics import stringWidth
    from reportlab.pdfgen.canvas import Canvas
  except ModuleNotFoundError as error:
    raise RuntimeError("Install reportlab for --pdf") from error

  page_width, page_height = landscape(letter)
  margin = 30
  columns = [("#", 24), ("Package", 118)]
  if with_conda:
    columns.append(("conda-forge", 105))
  columns += [("First upload", 73), ("Last upload", 73),
              (f"DL/{period}", 78)]
  used = sum(width for _, width in columns)
  columns.append(("Summary", page_width - 2 * margin - used))
  canvas = Canvas(path, pagesize=(page_width, page_height))
  page = 0

  def clip(value: str, width: float) -> str:
    value = " ".join(value.split())
    while value and stringWidth(value, "Helvetica", 8) > width - 5:
      value = value[:-1]
    return value

  def header() -> float:
    nonlocal page
    page += 1
    canvas.setFont("Helvetica-Bold", 11)
    title = clip(f"PyPI: {query} | {criterion} | page {page}",
                 page_width - 2 * margin)
    canvas.drawString(margin, page_height - margin, title)
    canvas.setFont("Helvetica-Bold", 8)
    x = margin
    for label, width in columns:
      canvas.drawString(x, page_height - margin - 20, label)
      x += width
    canvas.line(margin, page_height - margin - 23,
                page_width - margin, page_height - margin - 23)
    return page_height - margin - 36

  y = header()
  for rank, pkg in enumerate(rows, 1):
    if y < margin:
      canvas.showPage()
      y = header()
    values = [str(rank), pkg.name]
    if with_conda:
      values.append(pkg.conda or "-")
    values += [date_text(pkg.created), date_text(pkg.updated),
               count_text(pkg.downloads), pkg.summary]
    canvas.setFont("Helvetica", 8)
    x = margin
    for value, (_, width) in zip(values, columns):
      canvas.drawString(x, y, clip(value, width))
      x += width
    y -= 13
  canvas.save()


def parse_selection(selection: str, maximum: int) -> list[int]:
  """Accept comma/space separated indices and ranges such as '1, 3-5'."""
  selected = set()
  for token in re.split(r"[\s,]+", selection.strip()):
    if not token:
      continue
    match = re.fullmatch(r"(\d+)(?:-(\d+))?", token)
    if not match:
      raise ValueError(f"Invalid selection: {token}")
    first = int(match.group(1))
    last = int(match.group(2)) if match.group(2) else first
    if first < 1 or last > maximum or first > last:
      raise ValueError(f"Selection must be between 1 and {maximum}")
    selected.update(range(first, last + 1))
  return sorted(selected)


# ---------------------------------------------------------------------------
# Command-line interface
# ---------------------------------------------------------------------------
def positive(value: str) -> int:
  try:
    number = int(value)
  except ValueError as error:
    raise argparse.ArgumentTypeError("must be an integer") from error
  if number < 1:
    raise argparse.ArgumentTypeError("must be at least 1")
  return number


def iso_date(value: str) -> date:
  try:
    return date.fromisoformat(value)
  except ValueError as error:
    raise argparse.ArgumentTypeError("use YYYY-MM-DD") from error


def main() -> int:
  program = pathlib.Path(sys.argv[0]).name
  parser = argparse.ArgumentParser(
    description="Search PyPI package names and rank matched projects.",
    formatter_class=argparse.RawDescriptionHelpFormatter,
    epilog=(
      "Examples:\n"
      f"  {program} neuro image --sort downloads --period month\n"
      f"  {program} \"water maze\" --match any --sort relevance\n"
      f"  {program} neuro --sort newest --since 2026-09-01 "
      "--date-field created\n"
      f"  {program} neuro --sort updated --since 2026-08-01\n"
      f"  {program} atlas --sort downloads --period day\n"
      f"  {program} maze --sort downloads --period week\n"
      f"  {program} imaging --sort name --limit 30 "
      "--candidates 150\n"
      f"  {program} tracking --with-conda --csv results.csv\n"
      f"  {program} neuron --pdf results.pdf\n"
      f"  {program} microscopy --install\n\n"
      "Date options:\n"
      "  --since YYYY-MM-DD filters by the first file upload when paired\n"
      "  with --date-field created, or the last upload (default).\n"
      "  --period day/week/month selects recent download totals; it does\n"
      "  not select an arbitrary calendar interval.\n\n"
      "Notes:\n"
      "  Search matches package names. Ranking inspects up to --candidates\n"
      "  matches, not all PyPI. Downloads exclude known mirrors. Lifetime\n"
      "  totals are unavailable. Data is cached for 24 hours."
    )
  )
  parser.add_argument("query", nargs="+", help="one or more name keywords")
  parser.add_argument("--match", choices=("all", "any"), default="all",
                      help="require all keywords (default) or any keyword")
  parser.add_argument("--sort", choices=("relevance", "downloads", "newest",
                                         "updated", "name", "latest"),
                      default="updated",
                      help="rank by name match, downloads, first upload, "
                           "last upload, or alphabetical name; latest is "
                           "an alias for updated")
  parser.add_argument("--period", choices=("day", "week", "month"),
                      default="month", help="download period (default: month)")
  parser.add_argument("--since", type=iso_date, metavar="YYYY-MM-DD",
                      help="keep first/last file uploads on/after this date")
  parser.add_argument("--date-field", choices=("created", "updated"),
                      default="updated", help="first/last upload for --since")
  parser.add_argument("--limit", type=positive, default=20,
                      help="number of results to show (default: 20)")
  parser.add_argument("--candidates", type=positive, default=80,
                      help="maximum name matches to inspect (default: 80)")
  parser.add_argument("--threads", type=positive, default=4,
                      help="parallel metadata fetches (default: 4)")
  parser.add_argument("--with-conda", action="store_true",
                      help="show exact name matches in conda-forge")
  parser.add_argument("--csv", metavar="FILE", help="save results as CSV")
  parser.add_argument("--pdf", metavar="FILE",
                      help="save a multipage PDF (requires reportlab)")
  parser.add_argument("--install", action="store_true",
                      help="prompt to install selected packages with pip")
  args = parser.parse_intermixed_args()
  if args.threads > 16 or args.candidates > 500:
    parser.error("--threads must be <= 16 and --candidates <= 500")
  if not any(part.strip() for part in args.query):
    parser.error("supply at least one nonempty keyword")

  query = " ".join(args.query)
  try:
    with CONSOLE.status("Loading PyPI project names..."):
      names = fetch_pypi_index()
  except (requests.RequestException, ValueError, KeyError) as error:
    CONSOLE.print(f"[red]Could not load PyPI index:[/red] {error}")
    return 1

  candidates, total, fuzzy = find_candidates(
    args.query, names, args.match, args.candidates
  )
  if not candidates:
    CONSOLE.print("[yellow]No matching project names. Try --match any "
                  "or different keywords.[/yellow]")
    return 1
  if fuzzy:
    CONSOLE.print("[yellow]No exact name match; showing fuzzy "
                  "suggestions.[/yellow]")
  CONSOLE.print(f"Inspecting {len(candidates)} of {total:,} matched "
                "project names (ranked by name relevance).")

  with CONSOLE.status("Fetching project dates and recent downloads..."):
    with ThreadPoolExecutor(max_workers=args.threads) as pool:
      fetched = list(pool.map(lambda pair: package_info(pair, args.period),
                              candidates))
  rows = [pkg for pkg in fetched if pkg is not None]
  if not rows:
    CONSOLE.print("[red]No project metadata could be retrieved.[/red]")
    return 1
  if len(rows) < len(candidates):
    CONSOLE.print(f"[yellow]Metadata unavailable for "
                  f"{len(candidates) - len(rows)} projects.[/yellow]")
  missing = sum(pkg.downloads is None for pkg in rows)
  if missing:
    CONSOLE.print(f"[yellow]Downloads unavailable for {missing} "
                  "projects; shown as — and sorted last.[/yellow]")

  if args.since:
    rows = [pkg for pkg in rows if
            (getattr(pkg, args.date_field) is not None and
             getattr(pkg, args.date_field).date() >= args.since)]
  rows = sort_packages(rows, args.sort)[:args.limit]
  if not rows:
    CONSOLE.print("[yellow]No inspected projects meet the date filter.[/]")
    return 1

  if args.with_conda:
    with CONSOLE.status("Loading conda-forge names..."):
      conda_names = load_conda_names()
    if not conda_names:
      CONSOLE.print("[yellow]Could not load conda-forge names.[/yellow]")
    rows = [replace(pkg, conda=conda_names.get(canonical(pkg.name), ""))
            for pkg in rows]

  table = Table(title=Text(f"PyPI: {query} | sort: {args.sort}"))
  table.add_column("#", justify="right")
  table.add_column("Package")
  if args.with_conda:
    table.add_column("conda-forge", style="cyan")
  table.add_column("First upload UTC")
  table.add_column("Last upload UTC")
  table.add_column(f"DL / last {args.period}", justify="right")
  table.add_column("Summary")
  for index, pkg in enumerate(rows, 1):
    cells = [str(index), Text(pkg.name, style="bold")]
    if args.with_conda:
      cells.append(pkg.conda or "—")
    cells += [date_text(pkg.created), date_text(pkg.updated),
              count_text(pkg.downloads), Text(pkg.summary)]
    table.add_row(*cells)
  CONSOLE.print(table)

  try:
    if args.csv:
      write_csv(args.csv, rows, args.period)
      CONSOLE.print(f"CSV saved: {args.csv}")
    if args.pdf:
      write_pdf(args.pdf, query, args.sort, args.period, rows,
                args.with_conda)
      CONSOLE.print(f"PDF saved: {args.pdf}")
  except (OSError, RuntimeError) as error:
    CONSOLE.print(f"[red]Export failed:[/red] {error}")
    return 1

  if args.install:
    try:
      chosen = parse_selection(
        input("Package numbers to install (e.g. 1, 3-5): "), len(rows)
      )
      if chosen:
        packages = [rows[index - 1].name for index in chosen]
        subprocess.run([sys.executable, "-m", "pip", "install", *packages],
                       check=True)
      else:
        CONSOLE.print("No packages selected.")
    except (ValueError, EOFError, KeyboardInterrupt,
            subprocess.CalledProcessError) as error:
      CONSOLE.print(f"[red]Installation aborted:[/red] {error}")
      return 1
  return 0


if __name__ == "__main__":
  sys.exit(main())
