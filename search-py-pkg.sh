#!/usr/bin/env python3
"""Search PyPI project names and inspect their metadata and download counts.

Examples:
  search-python-packages data frame
  search-python-packages --match any r statistics
  search-python-packages torch --sort downloads --period month --limit 15
  search-python-packages "mixed model" --sort updated --csv results.csv
  search-python-packages sklearn --with-conda --install

Dependencies:
  python -m pip install requests
  python -m pip install rich       # optional, for formatted terminal tables
  python -m pip install reportlab  # only when using --pdf
"""

from __future__ import annotations

import argparse
import csv
import difflib
import hashlib
import html
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
from contextlib import nullcontext
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, replace
from datetime import date, datetime, timezone
from typing import Any, Iterable
from urllib.parse import quote

try:
  import requests
except ImportError:  # Keep --help usable without runtime dependencies.
  requests = None  # type: ignore[assignment]

try:
  from rich.console import Console
  from rich.table import Table
  from rich.text import Text
except ImportError:  # Plain-text fallback for systems without Rich.
  class Console:
    def __init__(self, **_kwargs: Any) -> None:
      pass

    def status(self, _message: str) -> Any:
      return nullcontext()

    def print(self, *values: Any) -> None:
      rendered = " ".join(str(value) for value in values)
      print(re.sub(r"\[/?[a-zA-Z #0-9]+\]", "", rendered))

  class Text(str):
    def __new__(cls, value: str, style: str | None = None) -> Text:
      return str.__new__(cls, value)

  class Table:
    def __init__(self, title: Any = None) -> None:
      self.title = title
      self.columns: list[str] = []
      self.rows: list[list[str]] = []

    def add_column(self, header: str, **_kwargs: Any) -> None:
      self.columns.append(header)

    def add_row(self, *values: Any) -> None:
      self.rows.append([str(value) for value in values])

    def __str__(self) -> str:
      lines = [str(self.title)] if self.title else []
      lines.append("\t".join(self.columns))
      lines.extend("\t".join(row) for row in self.rows)
      return "\n".join(lines)


# --- Constants and shared helpers ---------------------------------------------

PYPI_SIMPLE_URL = "https://pypi.org/simple/"
PYPI_PROJECT_URL = "https://pypi.org/pypi/{}/json"
PYPISTATS_URL = "https://pypistats.org/api/packages/{}"
CONDA_NAMES_URL = "https://api.anaconda.org/packages/conda-forge"
USER_AGENT = "search-python-packages/1.0 (PyPI metadata lookup)"
TIMEOUT = (10, 60)
INDEX_TTL = 24 * 60 * 60
METADATA_TTL = 24 * 60 * 60
STATS_TTL = 24 * 60 * 60

CONSOLE = Console(highlight=False, soft_wrap=True)
_THREAD_LOCAL = threading.local()


def cache_dir() -> Path:
  """Return the per-user cache directory, creating it when possible."""
  root = os.environ.get("XDG_CACHE_HOME")
  base = Path(root).expanduser() if root else Path.home() / ".cache"
  path = base / "search-python-packages"
  path.mkdir(parents=True, exist_ok=True)
  return path


def session() -> requests.Session:
  """Return a requests session local to the current worker thread."""
  current = getattr(_THREAD_LOCAL, "session", None)
  if current is None:
    current = requests.Session()
    current.headers.update({"User-Agent": USER_AGENT})
    _THREAD_LOCAL.session = current
  return current


def atomic_write(path: Path, content: str) -> None:
  """Write text to a file atomically, leaving the old file intact on failure."""
  path.parent.mkdir(parents=True, exist_ok=True)
  with tempfile.NamedTemporaryFile(
      "w", encoding="utf-8", dir=path.parent, delete=False
  ) as handle:
    temporary = Path(handle.name)
    handle.write(content)
  temporary.replace(path)


def read_fresh_cache(path: Path, ttl: int) -> str | None:
  """Return cached text only when it is newer than the supplied lifetime."""
  try:
    if datetime.now().timestamp() - path.stat().st_mtime <= ttl:
      return path.read_text(encoding="utf-8")
  except OSError:
    return None
  return None


def request_json(
    url: str,
    *,
    params: dict[str, str] | None = None,
    headers: dict[str, str] | None = None,
    ttl: int = STATS_TTL,
) -> Any:
  """Fetch JSON with a disk cache and stale-cache fallback."""
  prepared = requests.Request(
      "GET", url, params=params, headers=headers
  ).prepare()
  full_url = prepared.url or url
  cache_identity = full_url + json.dumps(headers or {}, sort_keys=True)
  key = hashlib.sha256(cache_identity.encode("utf-8")).hexdigest()
  path = cache_dir() / "http" / f"{key}.json"

  try:
    fresh = read_fresh_cache(path, ttl)
    if fresh is not None:
      return json.loads(fresh)
  except (OSError, ValueError):
    pass

  try:
    response = session().get(
        url, params=params, headers=headers, timeout=TIMEOUT
    )
    response.raise_for_status()
    payload = response.json()
    try:
      atomic_write(path, json.dumps(payload, ensure_ascii=False))
    except OSError:
      pass
    return payload
  except (requests.RequestException, ValueError):
    try:
      return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
      raise


def canonical(name: str) -> str:
  """Normalize a package name as PyPI does for comparisons."""
  return re.sub(r"[-_.]+", "-", name).lower()


def positive(value: str) -> int:
  """Parse a positive integer for command-line limits and worker counts."""
  try:
    number = int(value)
  except ValueError as error:
    raise argparse.ArgumentTypeError("must be a whole number") from error
  if number < 1:
    raise argparse.ArgumentTypeError("must be greater than zero")
  return number


def iso_date(value: str) -> date:
  """Parse an ISO calendar date supplied to --since."""
  try:
    return date.fromisoformat(value)
  except ValueError as error:
    raise argparse.ArgumentTypeError("use YYYY-MM-DD") from error


# --- PyPI index and candidate ranking -----------------------------------------

class ProjectIndexParser(HTMLParser):
  """Collect project names from PyPI's HTML Simple API index."""

  def __init__(self) -> None:
    super().__init__(convert_charrefs=True)
    self.names: list[str] = []
    self.in_anchor = False
    self.anchor_text: list[str] = []

  def handle_starttag(
      self,
      tag: str,
      attrs: list[tuple[str, str | None]],
  ) -> None:
    if tag == "a":
      self.in_anchor = True
      self.anchor_text = []

  def handle_data(self, data: str) -> None:
    if self.in_anchor:
      self.anchor_text.append(data)

  def handle_endtag(self, tag: str) -> None:
    if tag == "a" and self.in_anchor:
      name = "".join(self.anchor_text).strip()
      if name:
        self.names.append(name)
      self.in_anchor = False
      self.anchor_text = []


def fetch_pypi_index() -> list[str]:
  """Load project names from a fresh local cache or the PyPI Simple API."""
  path = cache_dir() / "pypi-project-names.txt"
  try:
    cached = read_fresh_cache(path, INDEX_TTL)
    if cached:
      return [line for line in cached.splitlines() if line]
  except OSError:
    pass

  parser = ProjectIndexParser()
  response: requests.Response | None = None
  try:
    response = session().get(
        PYPI_SIMPLE_URL,
        headers={"Accept": "application/vnd.pypi.simple.v1+html"},
        timeout=(10, 120),
        stream=True,
    )
    response.raise_for_status()
    for chunk in response.iter_content(chunk_size=1024 * 1024):
      if chunk:
        parser.feed(chunk.decode("utf-8", errors="replace"))
    parser.close()
  except requests.RequestException:
    try:
      stale = path.read_text(encoding="utf-8")
      if stale.strip():
        CONSOLE.print(
            "[yellow]PyPI is unreachable; using the cached name index.[/yellow]"
        )
        return [line for line in stale.splitlines() if line]
    except OSError:
      pass
    raise
  finally:
    if response is not None:
      response.close()

  if not parser.names:
    raise ValueError("PyPI returned an empty project index")
  try:
    atomic_write(path, "\n".join(parser.names) + "\n")
  except OSError:
    pass
  return parser.names


def query_terms(queries: Iterable[str]) -> list[str]:
  """Split entered keywords and normalize them for matching."""
  pieces = [
      piece
      for query in queries
      for piece in re.split(r"\s+", query.strip())
  ]
  return [canonical(piece) for piece in pieces if piece]


def find_candidates(
    queries: list[str],
    names: list[str],
    match: str,
    limit: int,
) -> tuple[list[tuple[str, float]], int, bool]:
  """Return ranked project-name candidates, match count, and fuzzy status."""
  terms = query_terms(queries)
  if not terms:
    return [], 0, False

  normalized = [(name, canonical(name)) for name in names]
  joined = canonical("-".join(terms))
  exact = [(name, 1000.0) for name, key in normalized if key == joined]
  if exact:
    return exact[:limit], len(exact), False

  matches: list[tuple[str, float]] = []
  for name, key in normalized:
    flags = [term in key for term in terms]
    accepted = all(flags) if match == "all" else any(flags)
    if not accepted:
      continue
    hits = sum(flags)
    score = 100.0 * hits / len(terms)
    if key.startswith(joined):
      score += 35.0
    elif joined in key:
      score += 25.0
    score -= max(0, len(key) - len(joined)) / 100.0
    matches.append((name, score))

  if matches:
    matches.sort(key=lambda pair: (-pair[1], canonical(pair[0])))
    return matches[:limit], len(matches), False

  lookup = {key: name for name, key in normalized}
  close = difflib.get_close_matches(
      joined, list(lookup), n=limit, cutoff=0.45
  )
  fuzzy = [(lookup[key], difflib.SequenceMatcher(None, joined, key).ratio())
           for key in close]
  fuzzy.sort(key=lambda pair: (-pair[1], canonical(pair[0])))
  return fuzzy, len(fuzzy), bool(fuzzy)


# --- Metadata and download statistics -----------------------------------------

@dataclass(frozen=True)
class Package:
  """The subset of PyPI and PyPI Stats data shown or exported by this tool."""

  name: str
  created: datetime | None
  updated: datetime | None
  downloads: int | None
  summary: str
  total_downloads: int | None = None
  conda: str = ""
  relevance: float = 0.0


def parse_datetime(value: str | None) -> datetime | None:
  """Parse PyPI timestamps and normalize them to UTC."""
  if not value:
    return None
  try:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
  except ValueError:
    return None
  if parsed.tzinfo is None:
    parsed = parsed.replace(tzinfo=timezone.utc)
  return parsed.astimezone(timezone.utc)


def release_dates(releases: dict[str, Any]) -> list[datetime]:
  """Return valid file-upload timestamps from the PyPI project JSON."""
  dates: list[datetime] = []
  for files in releases.values():
    if not isinstance(files, list):
      continue
    for item in files:
      if not isinstance(item, dict):
        continue
      timestamp = (item.get("upload_time_iso_8601")
                   or item.get("upload_time"))
      parsed = parse_datetime(timestamp)
      if parsed is not None:
        dates.append(parsed)
  return dates


def simple_index_dates(name: str) -> list[datetime]:
  """Get upload timestamps through PyPI's recommended Simple JSON API."""
  url = f"https://pypi.org/simple/{quote(name, safe='')}/"
  try:
    payload = request_json(
        url,
        headers={"Accept": "application/vnd.pypi.simple.v1+json"},
        ttl=METADATA_TTL,
    )
  except (requests.RequestException, ValueError, OSError):
    return []
  files = payload.get("files", []) if isinstance(payload, dict) else []
  if not isinstance(files, list):
    return []
  dates = []
  for item in files:
    if not isinstance(item, dict):
      continue
    parsed = parse_datetime(item.get("upload-time"))
    if parsed is not None:
      dates.append(parsed)
  return dates


def recent_downloads(name: str, period: str) -> int | None:
  """Fetch recent downloads, returning None when PyPI Stats has no value."""
  url = PYPISTATS_URL.format(quote(name, safe="")) + "/recent"
  try:
    payload = request_json(url, params={"period": period}, ttl=STATS_TTL)
  except (requests.RequestException, ValueError, OSError):
    return None
  data = payload.get("data", {}) if isinstance(payload, dict) else {}
  if not isinstance(data, dict):
    return None
  value = data.get(f"last_{period}")
  return value if isinstance(value, int) and value >= 0 else None


def available_history_downloads(name: str) -> int | None:
  """Sum the available mirror-excluded daily series (at most 180 days)."""
  url = PYPISTATS_URL.format(quote(name, safe="")) + "/overall"
  try:
    payload = request_json(url, params={"mirrors": "false"}, ttl=STATS_TTL)
  except (requests.RequestException, ValueError, OSError):
    return None
  data = payload.get("data", []) if isinstance(payload, dict) else []
  if not isinstance(data, list):
    return None
  values = [
      item.get("downloads") for item in data
      if isinstance(item, dict)
      and item.get("category") in (None, "without_mirrors")
      and isinstance(item.get("downloads"), int)
  ]
  return sum(values) if values else None


def package_info(
    candidate: tuple[str, float] | str,
    period: str,
    include_total: bool = False,
) -> Package | None:
  """Retrieve one project's metadata and its requested download counts."""
  if isinstance(candidate, tuple):
    name, relevance = candidate
  else:
    name, relevance = candidate, 0.0

  url = PYPI_PROJECT_URL.format(quote(name, safe=""))
  try:
    payload = request_json(url, ttl=METADATA_TTL)
  except (requests.RequestException, ValueError, OSError, KeyError):
    return None

  if not isinstance(payload, dict):
    return None
  info = payload.get("info")
  if not isinstance(info, dict):
    return None
  dates = simple_index_dates(name)
  if not dates:
    # Keep older PyPI metadata responses usable if the Simple API omits times.
    dates = release_dates(payload.get("releases", {}))
  created = min(dates) if dates else None
  updated = max(dates) if dates else None
  total = available_history_downloads(name) if include_total else None
  return Package(
      name=str(info.get("name") or name),
      created=created,
      updated=updated,
      downloads=recent_downloads(name, period),
      summary=str(info.get("summary") or ""),
      total_downloads=total,
      relevance=relevance,
  )


def sort_packages(rows: list[Package], sort_by: str) -> list[Package]:
  """Sort results by the selected metadata or download measure."""
  if sort_by == "downloads":
    return sorted(rows, key=lambda pkg: (
        pkg.downloads is None, -(pkg.downloads or 0), -pkg.relevance,
        canonical(pkg.name)))
  if sort_by == "total":
    return sorted(rows, key=lambda pkg: (
        pkg.total_downloads is None, -(pkg.total_downloads or 0),
        -pkg.relevance, canonical(pkg.name)))
  if sort_by == "newest":
    return sorted(rows, key=lambda pkg: (
        pkg.created is None, -(pkg.created.timestamp() if pkg.created else 0),
        -pkg.relevance, canonical(pkg.name)))
  if sort_by == "updated":
    return sorted(rows, key=lambda pkg: (
        pkg.updated is None, -(pkg.updated.timestamp() if pkg.updated else 0),
        -pkg.relevance, canonical(pkg.name)))
  if sort_by == "name":
    return sorted(rows, key=lambda pkg: canonical(pkg.name))
  return sorted(rows, key=lambda pkg: (-pkg.relevance, canonical(pkg.name)))


# --- Optional conda-forge lookup and output formatting -------------------------

def load_conda_names() -> dict[str, str]:
  """Load and cache the conda-forge package-name index."""
  payload = request_json(CONDA_NAMES_URL, ttl=INDEX_TTL)
  if not isinstance(payload, list):
    raise ValueError("conda-forge returned an unexpected package index")
  result: dict[str, str] = {}
  for item in payload:
    if isinstance(item, str):
      name = item
    elif isinstance(item, dict):
      name = item.get("name")
    else:
      name = None
    if isinstance(name, str) and name:
      result[canonical(name)] = name
  return result


def date_text(value: datetime | None) -> str:
  """Format a UTC date for terminal and export output."""
  return value.strftime("%Y-%m-%d") if value else "—"


def count_text(value: int | None) -> str:
  """Format download counts with grouping separators."""
  return f"{value:,}" if value is not None else "—"


def write_csv(path: str, rows: list[Package], period: str) -> None:
  """Write results as UTF-8 CSV with explicit date and download fields."""
  columns = [
      "package", "first_upload_utc", "last_upload_utc",
      f"downloads_last_{period}", "downloads_available_history_180d",
      "conda_forge", "summary",
  ]
  with open(path, "w", newline="", encoding="utf-8") as handle:
    writer = csv.DictWriter(handle, fieldnames=columns)
    writer.writeheader()
    for pkg in rows:
      writer.writerow({
          "package": pkg.name,
          "first_upload_utc": pkg.created.isoformat() if pkg.created else "",
          "last_upload_utc": pkg.updated.isoformat() if pkg.updated else "",
          f"downloads_last_{period}": pkg.downloads,
          "downloads_available_history_180d": pkg.total_downloads,
          "conda_forge": pkg.conda,
          "summary": pkg.summary,
      })


def write_pdf(
    path: str,
    query: str,
    sort_by: str,
    period: str,
    rows: list[Package],
    with_conda: bool,
) -> None:
  """Write a multipage landscape PDF report; ReportLab is optional."""
  try:
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import landscape, letter
    from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
    from reportlab.lib.units import inch
    from reportlab.platypus import (
        LongTable, Paragraph, SimpleDocTemplate, Spacer, TableStyle,
    )
  except ImportError as error:
    raise RuntimeError(
        "PDF export requires ReportLab: pip install reportlab"
    ) from error

  page = SimpleDocTemplate(
      path, pagesize=landscape(letter), rightMargin=0.35 * inch,
      leftMargin=0.35 * inch, topMargin=0.45 * inch, bottomMargin=0.4 * inch,
  )
  styles = getSampleStyleSheet()
  cell = ParagraphStyle("Cell", parent=styles["BodyText"], fontSize=7, leading=9)
  title = ParagraphStyle("TitleSmall", parent=styles["Title"], fontSize=14)
  story = [
      Paragraph("PyPI package search", title),
      Paragraph(
          f"Query: {html.escape(query)} &nbsp; | &nbsp; "
          f"Sort: {html.escape(sort_by)} &nbsp; | &nbsp; "
          f"Recent period: {html.escape(period)}",
          styles["BodyText"],
      ),
      Spacer(1, 0.15 * inch),
  ]
  headers = ["#", "Package"]
  if with_conda:
    headers.append("conda-forge")
  headers += ["First upload", "Last upload", f"DL / {period}"]
  if sort_by == "total":
    headers.append("DL / available history (~180d)")
  headers.append("Summary")
  data: list[list[Any]] = [
      [Paragraph(html.escape(item), cell) for item in headers]
  ]

  for index, pkg in enumerate(rows, 1):
    fields: list[str] = [str(index), pkg.name]
    if with_conda:
      fields.append(pkg.conda or "—")
    fields += [
        date_text(pkg.created), date_text(pkg.updated), count_text(pkg.downloads)
    ]
    if sort_by == "total":
      fields.append(count_text(pkg.total_downloads))
    fields.append(pkg.summary or "—")
    data.append([Paragraph(html.escape(value), cell) for value in fields])

  widths = [0.28 * inch, 1.35 * inch]
  if with_conda:
    widths.append(1.15 * inch)
  widths += [0.9 * inch, 0.9 * inch, 0.75 * inch]
  if sort_by == "total":
    widths.append(1.1 * inch)
  widths.append(3.8 * inch)
  table = LongTable(data, colWidths=widths, repeatRows=1, hAlign="LEFT")
  table.setStyle(TableStyle([
      ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#282a36")),
      ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
      ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
      ("VALIGN", (0, 0), (-1, -1), "TOP"),
      ("GRID", (0, 0), (-1, -1), 0.25, colors.HexColor("#b8b8b8")),
      ("ROWBACKGROUNDS", (0, 1), (-1, -1),
       [colors.white, colors.HexColor("#f2f2f2")]),
      ("LEFTPADDING", (0, 0), (-1, -1), 4),
      ("RIGHTPADDING", (0, 0), (-1, -1), 4),
      ("TOPPADDING", (0, 0), (-1, -1), 4),
      ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
  ]))
  story.append(table)
  page.build(story)


def parse_selection(value: str, row_count: int) -> list[int]:
  """Parse comma-separated row numbers and inclusive ranges, 1-based."""
  if not value.strip():
    return []
  selected: set[int] = set()
  for token in value.split(","):
    token = token.strip()
    if not token:
      raise ValueError("empty item in package selection")
    if re.fullmatch(r"\d+", token):
      start = end = int(token)
    elif re.fullmatch(r"\d+\s*-\s*\d+", token):
      first, last = re.split(r"\s*-\s*", token)
      start, end = int(first), int(last)
      if end < start:
        raise ValueError(f"range {token!r} runs backwards")
    else:
      raise ValueError(f"invalid selection item: {token!r}")
    if start < 1 or end > row_count:
      raise ValueError(f"selection {token!r} is outside 1-{row_count}")
    selected.update(range(start, end + 1))
  return sorted(selected)


# --- Command-line interface ----------------------------------------------------

LONG_HELP = """\
Search PyPI package names using one or more keywords, then inspect metadata for
the highest-ranked name matches. Matching is case-insensitive and normalizes
hyphens, underscores, and periods. By default every keyword must occur in the
project name; --match any relaxes that to at least one keyword.

Sort modes:
  downloads  Recent downloads for --period (default: month).
  total      Sum of available mirror-excluded PyPI Stats history. PyPI Stats
             retains at most 180 days; this is not a lifetime download total.
  newest     Most recently first-uploaded projects first.
  updated    Most recently uploaded project releases first.
  relevance  Best name match first.
  name       Alphabetical by normalized project name.

Examples:
  search-python-packages mixed model
  search-python-packages --match any brain behavior
  search-python-packages numpy --sort downloads --period week --limit 20
  search-python-packages "r stats" --sort updated --since 2024-01-01
  search-python-packages sklearn --with-conda --csv packages.csv
  search-python-packages torch --sort total --pdf torch.pdf
  search-python-packages pandas --install

Downloads and package metadata come from public PyPI and PyPI Stats endpoints.
Network failures may fall back to cached responses. PDF export additionally
requires ReportLab. --install prompts for result numbers and runs pip using the
same Python interpreter that launched this program.
"""


def build_parser() -> argparse.ArgumentParser:
  """Create the parser and the concise command-line help text."""
  parser = argparse.ArgumentParser(
      prog="search-python-packages",
      description="Search PyPI projects by one or more package-name keywords.",
      epilog="Run with --long-help for sorting notes and more examples.",
  )
  parser.add_argument(
      "query", nargs="+", help="one or more package-name keywords"
  )
  parser.add_argument(
      "--long-help", action="store_true",
      help="show extended help and examples",
  )
  parser.add_argument("--match", choices=("all", "any"), default="all",
                      help="require all keywords, or any (default: all)")
  parser.add_argument("--sort", choices=(
      "downloads", "total", "newest", "updated", "relevance", "name"
  ), default="downloads",
                      help="result ordering (default: downloads)")
  parser.add_argument("--period", choices=("day", "week", "month"),
                      default="month",
                      help="recent download window (default: month)")
  parser.add_argument("--limit", type=positive, default=20,
                      help="maximum rows to display/export (default: 20)")
  parser.add_argument("--candidates", type=positive, default=80,
                      help="maximum name matches to inspect (default: 80)")
  parser.add_argument("--threads", type=positive, default=4,
                      help="parallel metadata fetches (default: 4)")
  parser.add_argument("--with-conda", action="store_true",
                      help="show exact name matches in conda-forge")
  parser.add_argument("--since", type=iso_date, metavar="YYYY-MM-DD",
                      help="keep projects whose selected date is on/after it")
  parser.add_argument("--date-field", choices=("created", "updated"),
                      default="created",
                      help="date compared by --since (default: created)")
  parser.add_argument("--csv", metavar="FILE", help="save results as CSV")
  parser.add_argument("--pdf", metavar="FILE",
                      help="save a multipage PDF (requires reportlab)")
  parser.add_argument("--install", action="store_true",
                      help="prompt to install selected packages with pip")
  return parser


def main(argv: list[str] | None = None) -> int:
  """Run the search, display results, export files, and optionally install."""
  parser = build_parser()
  raw_argv = list(sys.argv[1:] if argv is None else argv)
  if "--long-help" in raw_argv:
    CONSOLE.print(LONG_HELP)
    return 0
  args = parser.parse_intermixed_args(raw_argv)

  if args.threads > 16 or args.candidates > 500:
    parser.error("--threads must be <= 16 and --candidates <= 500")
  if not any(part.strip() for part in args.query):
    parser.error("supply at least one nonempty keyword")
  if requests is None:
    CONSOLE.print("[red]Missing dependency:[/red] install requests with "
                  "python -m pip install requests")
    return 2

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
    CONSOLE.print(
        "[yellow]No exact name match; showing fuzzy suggestions.[/yellow]"
    )
  CONSOLE.print(f"Inspecting {len(candidates)} of {total:,} matched "
                "project names (ranked by name relevance).")

  with CONSOLE.status("Fetching project dates and recent downloads..."):
    with ThreadPoolExecutor(max_workers=args.threads) as pool:
      fetched = list(pool.map(
          lambda pair: package_info(pair, args.period, args.sort == "total"),
          candidates,
      ))
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
    rows = [pkg for pkg in rows
            if (getattr(pkg, args.date_field) is not None
                and getattr(pkg, args.date_field).date() >= args.since)]
  rows = sort_packages(rows, args.sort)[:args.limit]
  if not rows:
    CONSOLE.print("[yellow]No inspected projects meet the date filter.[/yellow]")
    return 1

  if args.with_conda:
    try:
      with CONSOLE.status("Loading conda-forge names..."):
        conda_names = load_conda_names()
      if not conda_names:
        CONSOLE.print("[yellow]Could not load conda-forge names.[/yellow]")
      rows = [replace(pkg, conda=conda_names.get(canonical(pkg.name), ""))
              for pkg in rows]
    except (requests.RequestException, ValueError, OSError) as error:
      CONSOLE.print(
          f"[yellow]Could not load conda-forge names: {error}[/yellow]"
      )
      rows = [replace(pkg, conda="") for pkg in rows]

  table = Table(title=Text(f"PyPI: {query} | sort: {args.sort}"))
  table.add_column("#", justify="right")
  table.add_column("Package")
  if args.with_conda:
    table.add_column("conda-forge", style="cyan")
  table.add_column("First upload UTC")
  table.add_column("Last upload UTC")
  table.add_column(f"DL / last {args.period}", justify="right")
  if args.sort == "total":
    table.add_column("DL / available history (~180d)", justify="right")
  table.add_column("Summary")
  for index, pkg in enumerate(rows, 1):
    cells: list[Any] = [str(index), Text(pkg.name, style="bold")]
    if args.with_conda:
      cells.append(pkg.conda or "—")
    cells += [date_text(pkg.created), date_text(pkg.updated),
              count_text(pkg.downloads)]
    if args.sort == "total":
      cells.append(count_text(pkg.total_downloads))
    cells.append(Text(pkg.summary))
    table.add_row(*cells)
  CONSOLE.print(table)

  try:
    if args.csv:
      write_csv(args.csv, rows, args.period)
      CONSOLE.print(f"CSV saved: {args.csv}")
    if args.pdf:
      write_pdf(args.pdf, query, args.sort, args.period, rows, args.with_conda)
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
