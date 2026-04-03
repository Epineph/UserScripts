#!/usr/bin/env python3
"""
scan_sensitive.py

Probabilistic recursive scanner for potentially sensitive content.

Purpose
-------
Scan files and directories recursively for likely sensitive data such as:
  - emails
  - phone numbers
  - addresses
  - personal identifiers in a deny-list
  - token-like strings
  - password / secret / token assignments
  - HTML / JSON dumps containing account-specific fields

This script is intentionally stdlib-only. It uses:
  - regex-based candidate extraction
  - context-sensitive scoring
  - simple shape / entropy heuristics
  - file-level aggregation
  - configurable aggressiveness threshold

It does NOT promise perfect detection. It provides:
  - a probability-like risk score
  - explainable findings
  - adjustable sensitivity

Examples
--------
1) Scan current directory recursively, balanced mode:
   ./scan_sensitive.py --path . --recursive

2) Scan only HTML and JSON, more aggressively:
   ./scan_sensitive.py --path . --recursive \
     --include '*.html,*.json' --aggressiveness 85

3) Print JSON results:
   ./scan_sensitive.py --path ~/repos --recursive --format json

4) Use a deny-list of your own known personal values:
   ./scan_sensitive.py --path . --recursive \
     --denylist-file personal_values.txt

5) Ignore generated files and scans above 2 MiB:
   ./scan_sensitive.py --path . --recursive \
     --exclude '.git,node_modules,dist,__pycache__' \
     --max-file-size 2097152

6) Conservative mode:
   ./scan_sensitive.py --path . --recursive --aggressiveness 25

7) Save JSON report:
   ./scan_sensitive.py --path . --recursive --format json \
     > sensitive_report.json
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import math
import os
import pathlib
import re
import sys
from dataclasses import dataclass, asdict
from typing import Iterable, Iterator, List, Optional, Sequence, Tuple


# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #

DEFAULT_INCLUDE = "*"
DEFAULT_EXCLUDE = (
  ".git,.svn,.hg,node_modules,dist,build,__pycache__,.mypy_cache,"
  ".pytest_cache,.ruff_cache,.venv,venv,.idea,.vscode"
)

TEXT_EXTENSIONS = {
  ".txt", ".md", ".rst", ".py", ".sh", ".bash", ".zsh", ".pl", ".pm",
  ".rb", ".js", ".ts", ".tsx", ".jsx", ".java", ".c", ".h", ".cpp",
  ".hpp", ".rs", ".go", ".php", ".lua", ".sql", ".xml", ".html",
  ".htm", ".json", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf",
  ".env", ".csv", ".tsv", ".tex", ".r", ".rmd", ".qmd", ".ps1"
}

CONTEXT_WINDOW = 80

# Base confidences for recognizers. These are intentionally modest.
BASE_SCORES = {
  "email": 0.55,
  "phone": 0.45,
  "orcid": 0.65,
  "address_like": 0.35,
  "password_assignment": 0.90,
  "secret_assignment": 0.88,
  "token_assignment": 0.85,
  "auth_header": 0.90,
  "jwt_like": 0.65,
  "csrf_field": 0.82,
  "session_field": 0.82,
  "person_denylist": 0.95,
  "high_entropy_token": 0.38,
  "json_personal_field": 0.72,
  "html_sensitive_param": 0.72,
}

SENSITIVE_CONTEXT_WEIGHTS = {
  "password": 0.18,
  "passwd": 0.18,
  "pwd": 0.16,
  "secret": 0.18,
  "token": 0.16,
  "apikey": 0.18,
  "api_key": 0.18,
  "authorization": 0.18,
  "bearer": 0.22,
  "csrf": 0.20,
  "session": 0.18,
  "cookie": 0.14,
  "email": 0.12,
  "mail": 0.08,
  "phone": 0.12,
  "cellphone": 0.16,
  "address": 0.12,
  "firstname": 0.14,
  "lastname": 0.14,
  "middlename": 0.12,
  "zipcity": 0.10,
  "zipcode": 0.10,
  "user": 0.06,
  "userid": 0.08,
  "name": 0.06,
  "document": 0.06,
  "cv": 0.05,
}


# --------------------------------------------------------------------------- #
# Data structures
# --------------------------------------------------------------------------- #

@dataclass
class Finding:
  kind: str
  line: int
  column: int
  start: int
  end: int
  match: str
  context: str
  score: float
  reasons: List[str]


@dataclass
class FileReport:
  path: str
  score: float
  decision: str
  findings: List[Finding]
  reasons: List[str]
  bytes_scanned: int


# --------------------------------------------------------------------------- #
# Utility functions
# --------------------------------------------------------------------------- #

def sigmoid(x: float) -> float:
  """Convert a raw score to a probability-like value."""
  try:
    return 1.0 / (1.0 + math.exp(-x))
  except OverflowError:
    return 0.0 if x < 0 else 1.0


def clamp(x: float, lo: float = 0.0, hi: float = 1.0) -> float:
  """Clamp a value into [lo, hi]."""
  return max(lo, min(hi, x))


def shannon_entropy(text: str) -> float:
  """Compute Shannon entropy for a string."""
  if not text:
    return 0.0
  counts = {}
  for ch in text:
    counts[ch] = counts.get(ch, 0) + 1
  total = len(text)
  entropy = 0.0
  for count in counts.values():
    p = count / total
    entropy -= p * math.log2(p)
  return entropy


def split_csv_patterns(value: str) -> List[str]:
  """Split comma-separated patterns, stripping whitespace."""
  return [part.strip() for part in value.split(",") if part.strip()]


def is_probably_text(path: pathlib.Path) -> bool:
  """
  Lightweight text heuristic.

  Uses extension first. If extension is unknown, read a small prefix and reject
  obvious binary files containing NUL bytes.
  """
  if path.suffix.lower() in TEXT_EXTENSIONS:
    return True

  try:
    with path.open("rb") as handle:
      prefix = handle.read(4096)
  except OSError:
    return False

  if b"\x00" in prefix:
    return False

  # Heuristic: accept if most bytes look like printable text or common
  # whitespace.
  if not prefix:
    return True

  printable = 0
  for b in prefix:
    if b in (9, 10, 13) or 32 <= b <= 126:
      printable += 1

  return (printable / len(prefix)) >= 0.85


def safe_read_text(path: pathlib.Path) -> Optional[str]:
  """
  Read text robustly.

  UTF-8 first, then a permissive fallback. Returns None on failure.
  """
  encodings = ("utf-8", "utf-8-sig", "latin-1")
  for encoding in encodings:
    try:
      return path.read_text(encoding=encoding, errors="strict")
    except (UnicodeDecodeError, OSError):
      continue

  try:
    return path.read_text(encoding="utf-8", errors="replace")
  except OSError:
    return None


def normalize_whitespace(text: str) -> str:
  """Collapse whitespace for compact context snippets."""
  return re.sub(r"\s+", " ", text).strip()


def compute_line_col(text: str, offset: int) -> Tuple[int, int]:
  """Convert absolute offset to 1-based line and column."""
  line = text.count("\n", 0, offset) + 1
  last_nl = text.rfind("\n", 0, offset)
  col = offset + 1 if last_nl == -1 else offset - last_nl
  return line, col


def context_slice(text: str, start: int, end: int,
                  width: int = CONTEXT_WINDOW) -> str:
  """Extract context around a match."""
  lo = max(0, start - width)
  hi = min(len(text), end + width)
  return normalize_whitespace(text[lo:hi])


def respect_gitignore_match(rel_path: str,
                            gitignore_patterns: Sequence[str]) -> bool:
  """
  Approximate .gitignore matching.

  This is intentionally simple, not a full gitignore engine.
  """
  for pat in gitignore_patterns:
    if fnmatch.fnmatch(rel_path, pat) or fnmatch.fnmatch(
      os.path.basename(rel_path), pat
    ):
      return True
  return False


def load_gitignore(root: pathlib.Path) -> List[str]:
  """Load a top-level .gitignore approximately."""
  gitignore = root / ".gitignore"
  patterns: List[str] = []
  if not gitignore.is_file():
    return patterns

  try:
    for line in gitignore.read_text(encoding="utf-8").splitlines():
      stripped = line.strip()
      if not stripped or stripped.startswith("#"):
        continue
      # Ignore negation patterns and advanced path semantics in this simple v1.
      if stripped.startswith("!"):
        continue
      patterns.append(stripped.rstrip("/"))
  except OSError:
    pass

  return patterns


def should_skip_path(path: pathlib.Path,
                     root: pathlib.Path,
                     include_patterns: Sequence[str],
                     exclude_patterns: Sequence[str],
                     respect_gitignore: bool,
                     gitignore_patterns: Sequence[str]) -> bool:
  """Decide whether to skip a file or directory path."""
  rel_path = str(path.relative_to(root))

  for part in path.parts:
    for ex in exclude_patterns:
      if fnmatch.fnmatch(part, ex):
        return True

  if respect_gitignore and respect_gitignore_match(rel_path, gitignore_patterns):
    return True

  if path.is_file():
    included = any(fnmatch.fnmatch(rel_path, pat) or
                   fnmatch.fnmatch(path.name, pat)
                   for pat in include_patterns)
    return not included

  return False


# --------------------------------------------------------------------------- #
# Recognizers
# --------------------------------------------------------------------------- #

EMAIL_RE = re.compile(
  r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b",
  re.IGNORECASE
)

PHONE_RE = re.compile(
  r"(?:\+?\d{1,3}[\s-]?)?(?:\(?\d{2,4}\)?[\s-]?)?"
  r"\d{2,4}[\s-]?\d{2,4}[\s-]?\d{2,4}\b"
)

ORCID_RE = re.compile(
  r"\b\d{4}-\d{4}-\d{4}-\d{3}[\dX]\b",
  re.IGNORECASE
)

ADDRESS_LIKE_RE = re.compile(
  r"\b[A-ZÆØÅ][A-Za-zÆØÅæøå' .-]{2,40}\s+\d{1,4}[A-Za-z]?"
  r"(?:,\s*\d{4}\s+[A-ZÆØÅa-zæøå .-]+)?\b"
)

PASSWORD_ASSIGN_RE = re.compile(
  r"(?i)\b(password|passwd|pwd)\b\s*[:=]\s*['\"]?([^\s'\";,#]+)"
)

SECRET_ASSIGN_RE = re.compile(
  r"(?i)\b(secret|api[_-]?key|access[_-]?key|private[_-]?key)\b"
  r"\s*[:=]\s*['\"]?([^\s'\";,#]+)"
)

TOKEN_ASSIGN_RE = re.compile(
  r"(?i)\b(token|bearer|csrf[_-]?token|session(id)?|auth(orization)?)\b"
  r"\s*[:=]\s*['\"]?([^\s'\";,#]+)"
)

AUTH_HEADER_RE = re.compile(
  r"(?i)\bauthorization\b\s*[:=]\s*['\"]?\s*bearer\s+([A-Za-z0-9._\-+/=]+)"
)

JWT_RE = re.compile(
  r"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"
)

CSRF_FIELD_RE = re.compile(
  r"(?i)\bcsrf[_-]?token\b"
)

SESSION_FIELD_RE = re.compile(
  r"(?i)\b(sessionid|session_id|session)\b"
)

JSON_PERSONAL_FIELD_RE = re.compile(
  r'(?i)"(email|cellphone|phone|address|firstname|lastname|middlename|'
  r'name|zipcity|zipcode|date_of_birth)"\s*:\s*(".*?"|\d+|null|true|false)'
)

HTML_SENSITIVE_PARAM_RE = re.compile(
  r"(?i)\b(address|email|phone|cellphone|csrf|session)\b"
)


# --------------------------------------------------------------------------- #
# Scoring
# --------------------------------------------------------------------------- #

def aggressiveness_to_threshold(aggressiveness: int) -> float:
  """
  Map aggressiveness in [0,100] to a file threshold in [0.2, 0.9].

  Higher aggressiveness => lower threshold => more findings flagged.
  """
  a = clamp(aggressiveness / 100.0, 0.0, 1.0)
  return 0.9 - (0.7 * a)


def token_shape_bonus(token: str) -> Tuple[float, List[str]]:
  """Assign a heuristic bonus for secret-like token shapes."""
  reasons: List[str] = []
  bonus = 0.0

  length = len(token)
  entropy = shannon_entropy(token)

  if length >= 16:
    bonus += 0.08
    reasons.append(f"token length {length} >= 16")

  if entropy >= 3.5:
    bonus += 0.08
    reasons.append(f"entropy {entropy:.2f} >= 3.5")

  if re.fullmatch(r"[A-Za-z0-9_\-+/=]+", token) and length >= 20:
    bonus += 0.06
    reasons.append("token uses restricted secret-like alphabet")

  if re.fullmatch(r"[A-Fa-f0-9]{32,}", token):
    bonus += 0.06
    reasons.append("long hex-like token")

  return bonus, reasons


def context_bonus(context: str) -> Tuple[float, List[str]]:
  """Boost score when sensitive context words are nearby."""
  text = context.lower()
  bonus = 0.0
  reasons: List[str] = []
  for word, weight in SENSITIVE_CONTEXT_WEIGHTS.items():
    if word in text:
      bonus += weight
      reasons.append(f"context contains '{word}'")
  return min(bonus, 0.45), reasons


def personal_field_bonus(path: pathlib.Path, context: str) -> Tuple[float,
                                                                    List[str]]:
  """Additional score for fields in obviously personal dumps."""
  reasons: List[str] = []
  bonus = 0.0

  lower_path = str(path).lower()
  if any(x in lower_path for x in ("cv", "profile", "account", "user", "dump")):
    bonus += 0.08
    reasons.append("file path suggests personal/account data")

  lowered = context.lower()
  if "var stash" in lowered or "window." in lowered:
    bonus += 0.06
    reasons.append("appears inside bootstrapped page/application state")

  if '"user"' in lowered or '"cv"' in lowered:
    bonus += 0.06
    reasons.append("JSON context references user/cv structure")

  return bonus, reasons


def score_match(kind: str,
                match_text: str,
                context: str,
                path: pathlib.Path) -> Tuple[float, List[str]]:
  """Compute score for a finding."""
  base = BASE_SCORES.get(kind, 0.30)
  score = base
  reasons = [f"base score from recognizer '{kind}' = {base:.2f}"]

  ctx_bonus, ctx_reasons = context_bonus(context)
  score += ctx_bonus
  reasons.extend(ctx_reasons)

  pf_bonus, pf_reasons = personal_field_bonus(path, context)
  score += pf_bonus
  reasons.extend(pf_reasons)

  if kind in {
    "password_assignment", "secret_assignment", "token_assignment",
    "auth_header", "jwt_like", "high_entropy_token"
  }:
    shape_bonus, shape_reasons = token_shape_bonus(match_text)
    score += shape_bonus
    reasons.extend(shape_reasons)

  return clamp(score), reasons


def aggregate_file_score(findings: Sequence[Finding]) -> float:
  """
  Aggregate multiple finding scores into a file-level risk estimate.

  P(file contains sensitive material) = 1 - product(1 - p_i)
  """
  if not findings:
    return 0.0

  product = 1.0
  for finding in findings:
    product *= (1.0 - clamp(finding.score))

  return clamp(1.0 - product)


# --------------------------------------------------------------------------- #
# Candidate extraction
# --------------------------------------------------------------------------- #

def yield_regex_matches(pattern: re.Pattern[str],
                        kind: str,
                        text: str) -> Iterator[Tuple[str, int, int]]:
  """Yield plain regex matches."""
  for m in pattern.finditer(text):
    yield kind, m.start(), m.end()


def yield_assignment_value_matches(pattern: re.Pattern[str],
                                   kind: str,
                                   text: str) -> Iterator[Tuple[str, int, int]]:
  """Yield only the assigned value group from assignment-style matches."""
  for m in pattern.finditer(text):
    if m.lastindex and m.lastindex >= 2:
      start, end = m.span(2)
    else:
      start, end = m.span()
    yield kind, start, end


def high_entropy_candidates(text: str) -> Iterator[Tuple[str, int, int]]:
  """
  Yield generic token candidates likely to be secrets.

  This is intentionally conservative to avoid absurd noise.
  """
  token_re = re.compile(r"\b[A-Za-z0-9_\-+/=]{20,}\b")
  for m in token_re.finditer(text):
    token = m.group(0)
    entropy = shannon_entropy(token)
    if entropy >= 3.7:
      yield "high_entropy_token", m.start(), m.end()


def denylist_candidates(text: str,
                        denylist: Sequence[str]) -> Iterator[Tuple[str, int, int]]:
  """Yield exact literal matches from a personal deny-list."""
  for entry in denylist:
    if not entry:
      continue
    escaped = re.escape(entry)
    for m in re.finditer(escaped, text, flags=re.IGNORECASE):
      yield "person_denylist", m.start(), m.end()


def extract_candidates(text: str,
                       denylist: Sequence[str]) -> Iterator[Tuple[str, int, int]]:
  """Collect all candidate spans."""
  yield from yield_regex_matches(EMAIL_RE, "email", text)
  yield from yield_regex_matches(PHONE_RE, "phone", text)
  yield from yield_regex_matches(ORCID_RE, "orcid", text)
  yield from yield_regex_matches(ADDRESS_LIKE_RE, "address_like", text)
  yield from yield_assignment_value_matches(
    PASSWORD_ASSIGN_RE, "password_assignment", text
  )
  yield from yield_assignment_value_matches(
    SECRET_ASSIGN_RE, "secret_assignment", text
  )
  yield from yield_assignment_value_matches(
    TOKEN_ASSIGN_RE, "token_assignment", text
  )
  yield from yield_assignment_value_matches(
    AUTH_HEADER_RE, "auth_header", text
  )
  yield from yield_regex_matches(JWT_RE, "jwt_like", text)
  yield from yield_regex_matches(CSRF_FIELD_RE, "csrf_field", text)
  yield from yield_regex_matches(SESSION_FIELD_RE, "session_field", text)
  yield from yield_regex_matches(
    JSON_PERSONAL_FIELD_RE, "json_personal_field", text
  )
  yield from yield_regex_matches(
    HTML_SENSITIVE_PARAM_RE, "html_sensitive_param", text
  )
  yield from high_entropy_candidates(text)
  yield from denylist_candidates(text, denylist)


# --------------------------------------------------------------------------- #
# File scanning
# --------------------------------------------------------------------------- #

def scan_text(path: pathlib.Path,
              text: str,
              denylist: Sequence[str],
              threshold: float) -> FileReport:
  """Scan one text file and return a report."""
  findings: List[Finding] = []

  seen_spans = set()
  for kind, start, end in extract_candidates(text, denylist):
    span_key = (kind, start, end)
    if span_key in seen_spans:
      continue
    seen_spans.add(span_key)

    matched = text[start:end]
    context = context_slice(text, start, end)
    score, reasons = score_match(kind, matched, context, path)
    line, column = compute_line_col(text, start)

    findings.append(
      Finding(
        kind=kind,
        line=line,
        column=column,
        start=start,
        end=end,
        match=matched,
        context=context,
        score=score,
        reasons=reasons,
      )
    )

  findings.sort(key=lambda f: f.score, reverse=True)
  file_score = aggregate_file_score(findings)
  decision = "FLAG" if file_score >= threshold else "REVIEW"

  reasons = []
  if findings:
    top = findings[0]
    reasons.append(
      f"{len(findings)} finding(s), top finding '{top.kind}' score={top.score:.2f}"
    )
  else:
    reasons.append("no candidates detected")

  return FileReport(
    path=str(path),
    score=file_score,
    decision=decision if findings else "CLEAN",
    findings=findings,
    reasons=reasons,
    bytes_scanned=len(text.encode("utf-8", errors="replace")),
  )


def iter_files(root: pathlib.Path,
               recursive: bool,
               include_patterns: Sequence[str],
               exclude_patterns: Sequence[str],
               respect_gitignore: bool) -> Iterator[pathlib.Path]:
  """Yield files to scan."""
  gitignore_patterns = load_gitignore(root) if respect_gitignore else []

  if root.is_file():
    yield root
    return

  walker = root.rglob("*") if recursive else root.glob("*")
  for path in walker:
    try:
      if should_skip_path(
        path=path,
        root=root,
        include_patterns=include_patterns,
        exclude_patterns=exclude_patterns,
        respect_gitignore=respect_gitignore,
        gitignore_patterns=gitignore_patterns,
      ):
        continue
    except ValueError:
      # If path.relative_to(root) fails for unusual symlink cases, skip.
      continue

    if path.is_file():
      yield path


def load_list_file(path: Optional[str]) -> List[str]:
  """Load non-empty lines from a file, or return an empty list."""
  if not path:
    return []

  file_path = pathlib.Path(path)
  if not file_path.is_file():
    raise FileNotFoundError(f"List file not found: {path}")

  values = []
  for line in file_path.read_text(encoding="utf-8").splitlines():
    stripped = line.strip()
    if stripped and not stripped.startswith("#"):
      values.append(stripped)
  return values


# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #

def finding_to_dict(finding: Finding) -> dict:
  """Serialize one finding."""
  return asdict(finding)


def report_to_dict(report: FileReport) -> dict:
  """Serialize one file report."""
  return {
    "path": report.path,
    "score": report.score,
    "decision": report.decision,
    "reasons": report.reasons,
    "bytes_scanned": report.bytes_scanned,
    "findings": [finding_to_dict(f) for f in report.findings],
  }


def print_text_report(reports: Sequence[FileReport],
                      threshold: float,
                      show_all: bool) -> None:
  """Print human-readable output."""
  print(f"Threshold: {threshold:.2f}")
  print()

  shown = 0
  for report in reports:
    if not show_all and report.decision == "CLEAN":
      continue

    shown += 1
    print(f"Path: {report.path}")
    print(f"Score: {report.score:.3f}")
    print(f"Decision: {report.decision}")
    for reason in report.reasons:
      print(f"Reason: {reason}")

    for finding in report.findings[:10]:
      print(
        f"  - [{finding.kind}] line={finding.line} col={finding.column} "
        f"score={finding.score:.2f}"
      )
      print(f"    Match:   {truncate(finding.match, 120)}")
      print(f"    Context: {truncate(finding.context, 160)}")

    if len(report.findings) > 10:
      print(f"  ... {len(report.findings) - 10} more finding(s)")
    print()

  if shown == 0:
    print("No flagged or review-worthy files were found.")


def truncate(text: str, width: int) -> str:
  """Truncate a string for display."""
  return text if len(text) <= width else (text[: width - 3] + "...")


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

def build_parser() -> argparse.ArgumentParser:
  """Construct the CLI parser."""
  parser = argparse.ArgumentParser(
    description=(
      "Recursively scan files for potentially sensitive content using a "
      "probability-like scoring model."
    )
  )

  parser.add_argument(
    "--path",
    required=True,
    help="Path to a file or directory to scan."
  )
  parser.add_argument(
    "--recursive",
    action="store_true",
    help="Recurse into subdirectories."
  )
  parser.add_argument(
    "--include",
    default=DEFAULT_INCLUDE,
    help=(
      "Comma-separated glob patterns to include. Default: '*' "
      "(example: '*.py,*.json,*.html')."
    )
  )
  parser.add_argument(
    "--exclude",
    default=DEFAULT_EXCLUDE,
    help=(
      "Comma-separated path or directory globs to exclude. "
      "Default excludes common generated and VCS directories."
    )
  )
  parser.add_argument(
    "--respect-gitignore",
    action="store_true",
    help="Approximate respect for top-level .gitignore patterns."
  )
  parser.add_argument(
    "--max-file-size",
    type=int,
    default=2 * 1024 * 1024,
    help="Maximum file size in bytes to scan. Default: 2097152."
  )
  parser.add_argument(
    "--aggressiveness",
    type=int,
    default=60,
    help=(
      "Aggressiveness from 0 to 100. Higher values lower the threshold and "
      "flag more files. Default: 60."
    )
  )
  parser.add_argument(
    "--denylist-file",
    help=(
      "Path to a file containing one personal sensitive value per line. "
      "Exact literal matches from this list get very high scores."
    )
  )
  parser.add_argument(
    "--allowlist-file",
    help=(
      "Path to a file containing one literal value per line to suppress from "
      "output when matched exactly."
    )
  )
  parser.add_argument(
    "--format",
    choices=("text", "json"),
    default="text",
    help="Output format. Default: text."
  )
  parser.add_argument(
    "--show-all",
    action="store_true",
    help="Show clean files too."
  )
  parser.add_argument(
    "--min-finding-score",
    type=float,
    default=0.20,
    help="Discard findings below this score. Default: 0.20."
  )

  return parser


def apply_allowlist(report: FileReport,
                    allowlist: Sequence[str],
                    min_finding_score: float) -> FileReport:
  """Suppress exact allowlisted findings and low-score noise."""
  allowset = {x.lower() for x in allowlist}

  filtered_findings = []
  for finding in report.findings:
    if finding.match.lower() in allowset:
      continue
    if finding.score < min_finding_score:
      continue
    filtered_findings.append(finding)

  filtered_findings.sort(key=lambda f: f.score, reverse=True)
  score = aggregate_file_score(filtered_findings)

  if not filtered_findings:
    decision = "CLEAN"
    reasons = ["all findings suppressed by allowlist or score floor"]
  else:
    decision = report.decision
    reasons = [
      f"{len(filtered_findings)} finding(s) remain after filtering"
    ]

  return FileReport(
    path=report.path,
    score=score,
    decision=decision if filtered_findings else "CLEAN",
    findings=filtered_findings,
    reasons=reasons,
    bytes_scanned=report.bytes_scanned,
  )


def main(argv: Optional[Sequence[str]] = None) -> int:
  """CLI entry point."""
  parser = build_parser()
  args = parser.parse_args(argv)

  if not (0 <= args.aggressiveness <= 100):
    parser.error("--aggressiveness must be between 0 and 100.")

  root = pathlib.Path(args.path).expanduser().resolve()
  if not root.exists():
    parser.error(f"Path does not exist: {root}")

  include_patterns = split_csv_patterns(args.include)
  exclude_patterns = split_csv_patterns(args.exclude)

  denylist = load_list_file(args.denylist_file)
  allowlist = load_list_file(args.allowlist_file)

  threshold = aggressiveness_to_threshold(args.aggressiveness)
  reports: List[FileReport] = []

  for path in iter_files(
    root=root,
    recursive=args.recursive,
    include_patterns=include_patterns,
    exclude_patterns=exclude_patterns,
    respect_gitignore=args.respect_gitignore,
  ):
    try:
      if path.stat().st_size > args.max_file_size:
        continue
    except OSError:
      continue

    if not is_probably_text(path):
      continue

    text = safe_read_text(path)
    if text is None:
      continue

    report = scan_text(
      path=path,
      text=text,
      denylist=denylist,
      threshold=threshold,
    )
    report = apply_allowlist(
      report=report,
      allowlist=allowlist,
      min_finding_score=args.min_finding_score,
    )
    reports.append(report)

  reports.sort(key=lambda r: r.score, reverse=True)

  if args.format == "json":
    payload = {
      "path": str(root),
      "threshold": threshold,
      "aggressiveness": args.aggressiveness,
      "reports": [report_to_dict(r) for r in reports],
    }
    json.dump(payload, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
  else:
    print_text_report(
      reports=reports,
      threshold=threshold,
      show_all=args.show_all,
    )

  return 0


if __name__ == "__main__":
  raise SystemExit(main())
