#!/usr/bin/env python3
# ──────────────────────────────────────────────────────────────────────────────
# cargo-search — Search crates.io, rank results, keep only cargo-installable
# ──────────────────────────────────────────────────────────────────────────────
"""
Search crates.io, rank matches (downloads / recent / updated / relevance),
detect which crates expose runnable binaries (installable via `cargo install`),
and optionally install selected crates.

Rationale
---------
- `cargo install` works only for packages with executable targets (bin/example);
  libraries alone are not installable. We detect binaries by downloading the
  crate tarball and inspecting Cargo.toml and the source layout. [Ref: Cargo]
- crates.io’s search API returns metadata (name, description, downloads,
  recent_downloads, max_version, updated_at), but *not* target types. [Ref:
  Web API]. Hence explicit inspection is required.

Key features
------------
- Fast search via crates.io API.
- Robust installability check (no guesses): looks for `[[bin]]`, `src/main.rs`,
  or `src/bin/*.rs` inside the crate archive.
- Sort by: relevance (server order), all-time downloads, recent downloads,
  or last update time.
- Export CSV.
- Interactive selection + `cargo install` (all binaries by default).

Usage examples
--------------
# Fuzzy query; show top 40, filter to installables, sort by recent downloads
./cargo-search fuzz --limit 40 --sort recent

# Same, but show non-installables (libraries) too
./cargo-search fuzz --limit 40 --include-libs

# Sort by updated time and export CSV
./cargo-search "websocket toolkit" --sort updated --csv ws.csv

# Pick from table and install via `cargo install`
./cargo-search cargo --limit 50 --install

Notes
-----
- Network: uses polite concurrency and a small cache (~$XDG_CACHE_HOME).
- “Installable” = has at least one binary target. Examples are *not*
  considered installable unless you pass `--allow-examples`.

References
----------
- Cargo install semantics: https://doc.rust-lang.org/cargo/commands/cargo-install.html
- Cargo registry Web API (search endpoint): https://doc.rust-lang.org/cargo/reference/registry-web-api.html
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import os
import re
import sys
import tarfile
import time
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Optional

try:
  import tomllib  # Py3.11+
except ModuleNotFoundError:  # pragma: no cover
  import tomli as tomllib  # type: ignore

import requests
from rapidfuzz import fuzz, process
from rich.console import Console
from rich.table import Table

# ──────────────────────────────────────────────────────────────────────────────
# Constants & endpoints
# ──────────────────────────────────────────────────────────────────────────────
API_SEARCH = "https://crates.io/api/v1/crates"
API_CRATE  = "https://crates.io/api/v1/crates/{name}"
API_DL     = "https://crates.io/api/v1/crates/{name}/{vers}/download"

UA = "cargo-search/1.0 (+https://crates.io)"
TIMEOUT = 25

CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME",
                                Path.home() / ".cache")) / "cargo_search"
CACHE_DIR.mkdir(parents=True, exist_ok=True)

console = Console()


@dataclass(frozen=True)
class Row:
  name: str
  version: str
  desc: str
  downloads: int
  recent: int
  updated: datetime
  installable: bool
  bins: tuple[str, ...]  # binary target names (if any)
  examples: tuple[str, ...]  # example targets (not installed by default)


# ──────────────────────────────────────────────────────────────────────────────
# Small HTTP helpers
# ──────────────────────────────────────────────────────────────────────────────
def _get(url: str, params: dict | None = None) -> requests.Response:
  hdr = {"User-Agent": UA, "Accept": "application/json"}
  r = requests.get(url, params=params, headers=hdr, timeout=TIMEOUT)
  r.raise_for_status()
  return r


def _get_json(url: str, params: dict | None = None) -> dict:
  return _get(url, params=params).json()


# ──────────────────────────────────────────────────────────────────────────────
# Parsing & ranking helpers
# ──────────────────────────────────────────────────────────────────────────────
def _parse_dt(s: str | None) -> datetime:
  if not s:
    return datetime

