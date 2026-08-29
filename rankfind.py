#!/usr/bin/env python3
"""Search, filter, rank, and colourise files without modifying them.

``rankfind`` handles searches that become awkward as a chain of ``fd``,
``rg``, ``awk``, and ``sort`` commands.  It deliberately remains read-only.

Predicate logic
---------------

* Different positive groups are combined with AND.
* Values inside the exact-name, extension, and glob groups use OR.
* Name/content terms use OR by default and can be changed to AND.
* Any exclusion vetoes a file.

For example, this means that::

  rankfind ROOT -e conf -n user -c monitor --exclude-dir scripts

selects a ``.conf`` file whose name contains ``user`` and whose contents
contain ``monitor``, unless it occurs below a directory named ``scripts``.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import datetime as dt
import fnmatch
import functools
import json
import math
import os
import re
import stat
import sys
from collections.abc import Iterable, Iterator, Sequence
from pathlib import Path


PROGRAM = "rankfind"
VERSION = "1.0.0"

# Safety limits.  CLI options may tighten these values, but cannot exceed the
# hard scan/output ceilings or weaken the hard minimum term length.
HARD_MIN_TERM_LENGTH = 2
DEFAULT_MIN_TERM_LENGTH = 3
DEFAULT_SCAN_LIMIT = 250_000
HARD_SCAN_LIMIT = 2_000_000
DEFAULT_RESULT_LIMIT = 100
HARD_RESULT_LIMIT = 10_000
DEFAULT_MAX_FILE_SIZE = 10 * 1024 * 1024


class SearchError(RuntimeError):
  """A controlled search or validation failure."""


@dataclasses.dataclass(slots=True)
class Candidate:
  """A file that passed inexpensive path and filename predicates."""

  path: Path
  root: Path
  relative: str
  size: int
  mtime: float
  score: float


@dataclasses.dataclass(slots=True)
class Result:
  """A final match with its rankable measurements."""

  path: Path
  root: Path
  relative: str
  size: int
  mtime: float
  score: float
  hits: int


@dataclasses.dataclass(slots=True)
class SearchStats:
  """Counters used in the final summary."""

  visited: int = 0
  candidates: int = 0
  matched: int = 0
  unreadable: int = 0
  binary: int = 0
  too_large: int = 0


@dataclasses.dataclass(slots=True)
class TermMatcher:
  """A compiled content matcher."""

  source: str
  regex: re.Pattern[str]

  def count(self, text: str) -> int:
    """Count non-overlapping matches in *text*."""

    return sum(1 for _ in self.regex.finditer(text))


def build_parser() -> argparse.ArgumentParser:
  """Build and return the command-line parser."""

  description = (
    "Recursively select files by name/path/content, exclude unwanted "
    "matches, and sort or score the result. The command never writes to "
    "searched files."
  )
  epilog = """
Examples:
  # Exact basenames taken from one directory, searched below another root.
  rankfind /shared --names-from ~/.config/hypr/UserConfigs --sort name

  # The same lookup, but collect reference names recursively.
  rankfind /shared --names-from ./reference --names-from-recursive

  # .conf + filename term + content term - scripts directory.
  rankfind ~/.config/hypr -e conf -n user -c monitor \\
    --exclude-dir scripts --sort score

  # Rank all config files by literal occurrences of two alternative terms.
  rankfind ~/.config/hypr -e conf -c monitor -c workspace \\
    --content-mode any --sort hits

  # Machine-readable, NUL-delimited paths for xargs or while-read.
  rankfind . -g '*.sh' --format paths -0

Safety:
  Substring/content terms are at least 3 meaningful characters by default.
  --min-term-length may raise that threshold and must remain above the hard
  floor of 2. A search needs a positive selector unless --all is supplied.
"""

  parser = argparse.ArgumentParser(
    prog=PROGRAM,
    description=description,
    epilog=epilog,
    formatter_class=argparse.RawDescriptionHelpFormatter,
  )
  parser.add_argument(
    "roots",
    nargs="*",
    metavar="ROOT",
    help="search root(s); default: current directory",
  )
  parser.add_argument(
    "--version",
    action="version",
    version=f"%(prog)s {VERSION}",
  )

  traversal = parser.add_argument_group("traversal")
  traversal.add_argument(
    "-H",
    "--hidden",
    action="store_true",
    help="include dotfiles and descend into hidden directories",
  )
  traversal.add_argument(
    "-L",
    "--follow",
    action="store_true",
    help="follow directory symlinks (inode cycles are suppressed)",
  )
  traversal.add_argument(
    "--max-depth",
    type=positive_int,
    help="maximum depth below each root; root files have depth 1",
  )
  traversal.add_argument(
    "--scan-limit",
    type=positive_int,
    default=DEFAULT_SCAN_LIMIT,
    metavar="N",
    help=f"abort after visiting N files (default: {DEFAULT_SCAN_LIMIT:,})",
  )

  positive = parser.add_argument_group("positive selectors")
  positive.add_argument(
    "-n",
    "--name",
    action="append",
    default=[],
    metavar="TEXT",
    help="basename contains TEXT; repeatable",
  )
  positive.add_argument(
    "--name-mode",
    choices=("any", "all"),
    default="any",
    help="how repeated --name terms combine (default: any)",
  )
  positive.add_argument(
    "-e",
    "--ext",
    action="append",
    default=[],
    metavar="EXT",
    help="extension, with or without a dot; repeatable and OR-combined",
  )
  positive.add_argument(
    "-g",
    "--glob",
    action="append",
    default=[],
    metavar="GLOB",
    help="basename/path glob; repeatable and OR-combined",
  )
  positive.add_argument(
    "-x",
    "--exact",
    action="append",
    default=[],
    metavar="NAME",
    help="exact basename; repeatable and OR-combined",
  )
  positive.add_argument(
    "--names-from",
    action="append",
    default=[],
    type=Path,
    metavar="DIR",
    help="accept basenames present in DIR; repeatable",
  )
  positive.add_argument(
    "--names-from-recursive",
    action="store_true",
    help="collect --names-from basenames recursively rather than directly",
  )
  positive.add_argument(
    "-c",
    "--content",
    action="append",
    default=[],
    metavar="TEXT",
    help="file content contains TEXT; repeatable",
  )
  positive.add_argument(
    "--content-mode",
    choices=("any", "all"),
    default="any",
    help="how repeated --content terms combine (default: any)",
  )
  positive.add_argument(
    "--all",
    action="store_true",
    help="explicitly allow a search without any positive selector",
  )

  matching = parser.add_argument_group("matching semantics")
  matching.add_argument(
    "-s",
    "--case-sensitive",
    action="store_true",
    help="make name, glob, extension, and content matching case-sensitive",
  )
  matching.add_argument(
    "--content-regex",
    action="store_true",
    help="interpret content and excluded-content terms as Python regexes",
  )
  matching.add_argument(
    "-w",
    "--word",
    action="store_true",
    help="require whole-word content matches",
  )
  matching.add_argument(
    "--min-term-length",
    type=positive_int,
    default=DEFAULT_MIN_TERM_LENGTH,
    metavar="N",
    help=(
      "minimum meaningful characters in substring/content terms "
      f"(default: {DEFAULT_MIN_TERM_LENGTH})"
    ),
  )

  negative = parser.add_argument_group("exclusions (each is a veto)")
  negative.add_argument(
    "--exclude-name",
    action="append",
    default=[],
    metavar="TEXT",
    help="exclude basenames containing TEXT; repeatable",
  )
  negative.add_argument(
    "--exclude-ext",
    action="append",
    default=[],
    metavar="EXT",
    help="exclude an extension; repeatable",
  )
  negative.add_argument(
    "--exclude-glob",
    action="append",
    default=[],
    metavar="GLOB",
    help="exclude a basename/path glob; repeatable",
  )
  negative.add_argument(
    "--exclude-dir",
    action="append",
    default=[],
    metavar="GLOB",
    help="do not descend into matching directory components; repeatable",
  )
  negative.add_argument(
    "--exclude-content",
    action="append",
    default=[],
    metavar="TEXT",
    help="exclude files containing TEXT; repeatable",
  )
  negative.add_argument(
    "--exclude-source",
    action="store_true",
    help="exclude every --names-from directory from the result",
  )

  content = parser.add_argument_group("content scanning")
  content.add_argument(
    "--max-file-size",
    type=parse_size,
    default=DEFAULT_MAX_FILE_SIZE,
    metavar="SIZE",
    help="largest file read for content, e.g. 10M or 512K (default: 10M)",
  )
  content.add_argument(
    "--binary-text",
    action="store_true",
    help="search NUL-containing files as text instead of skipping them",
  )
  content.add_argument(
    "--encoding",
    default="utf-8",
    help="text encoding used for content scans (default: utf-8)",
  )
  content.add_argument(
    "-j",
    "--jobs",
    type=positive_int,
    default=min(32, (os.cpu_count() or 1) + 4),
    metavar="N",
    help="parallel content readers",
  )

  ranking = parser.add_argument_group("ranking and sorting")
  ranking.add_argument(
    "--sort",
    choices=("score", "hits", "name", "path", "size", "mtime"),
    default="score",
    help="result ordering (default: score)",
  )
  ranking.add_argument(
    "-r",
    "--reverse",
    action="store_true",
    help="reverse the natural order for the selected sort key",
  )
  ranking.add_argument(
    "--weight-exact",
    type=nonnegative_float,
    default=100.0,
    metavar="N",
    help="score contribution from exact-name matching (default: 100)",
  )
  ranking.add_argument(
    "--weight-name",
    type=nonnegative_float,
    default=20.0,
    metavar="N",
    help="score per filename-term occurrence (default: 20)",
  )
  ranking.add_argument(
    "--weight-glob",
    type=nonnegative_float,
    default=15.0,
    metavar="N",
    help="score per matching include glob (default: 15)",
  )
  ranking.add_argument(
    "--weight-ext",
    type=nonnegative_float,
    default=10.0,
    metavar="N",
    help="score contribution from extension matching (default: 10)",
  )
  ranking.add_argument(
    "--weight-content",
    type=nonnegative_float,
    default=1.0,
    metavar="N",
    help="score per positive content occurrence (default: 1)",
  )

  output = parser.add_argument_group("output")
  output.add_argument(
    "--limit",
    type=positive_int,
    default=DEFAULT_RESULT_LIMIT,
    metavar="N",
    help=f"show at most N results (default: {DEFAULT_RESULT_LIMIT})",
  )
  output.add_argument(
    "--format",
    choices=("table", "plain", "json", "paths"),
    default="table",
    help="output format (default: table)",
  )
  output.add_argument(
    "-0",
    "--print0",
    action="store_true",
    help="NUL-terminate --format paths output",
  )
  output.add_argument(
    "--color",
    choices=("auto", "always", "never"),
    default="auto",
    help="colour policy for Rich tables (default: auto)",
  )
  output.add_argument(
    "--gradient",
    choices=("relative", "fixed"),
    default="relative",
    help="map colours to result range or a fixed maximum (default: relative)",
  )
  output.add_argument(
    "--gradient-max",
    type=positive_float,
    default=100.0,
    metavar="N",
    help="score represented by green with --gradient fixed (default: 100)",
  )
  output.add_argument(
    "--no-summary",
    action="store_true",
    help="suppress the search summary",
  )

  return parser


def positive_int(value: str) -> int:
  """Parse a strictly positive integer for argparse."""

  try:
    number = int(value)
  except ValueError as exc:
    raise argparse.ArgumentTypeError("must be an integer") from exc
  if number < 1:
    raise argparse.ArgumentTypeError("must be at least 1")
  return number


def nonnegative_float(value: str) -> float:
  """Parse a finite, non-negative floating-point number."""

  try:
    number = float(value)
  except ValueError as exc:
    raise argparse.ArgumentTypeError("must be a number") from exc
  if not math.isfinite(number) or number < 0:
    raise argparse.ArgumentTypeError("must be finite and non-negative")
  return number


def positive_float(value: str) -> float:
  """Parse a finite, positive floating-point number."""

  number = nonnegative_float(value)
  if number == 0:
    raise argparse.ArgumentTypeError("must be greater than zero")
  return number


def parse_size(value: str) -> int:
  """Parse an integer byte count with an optional binary size suffix."""

  match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([kmgt]?)i?b?\s*", value,
                       re.IGNORECASE)
  if not match:
    raise argparse.ArgumentTypeError(
      "expected bytes or a suffix such as 512K, 10M, or 1G"
    )
  factors = {
    "": 1,
    "k": 1024,
    "m": 1024**2,
    "g": 1024**3,
    "t": 1024**4,
  }
  result = int(float(match.group(1)) * factors[match.group(2).lower()])
  if result < 1:
    raise argparse.ArgumentTypeError("size must be at least one byte")
  return result


def meaningful_length(term: str, regex_mode: bool) -> int:
  """Return a conservative measure used by the broad-query guard."""

  if not regex_mode:
    return len(term.strip())
  return len(re.sub(r"[^\w]+", "", term, flags=re.UNICODE))


def validate_args(args: argparse.Namespace) -> None:
  """Validate combinations and enforce non-negotiable safety ceilings."""

  if args.min_term_length <= HARD_MIN_TERM_LENGTH:
    raise SearchError(
      "--min-term-length must be greater than the hard floor "
      f"{HARD_MIN_TERM_LENGTH}"
    )
  if args.scan_limit > HARD_SCAN_LIMIT:
    raise SearchError(
      f"--scan-limit cannot exceed the hard ceiling {HARD_SCAN_LIMIT:,}"
    )
  if args.limit > HARD_RESULT_LIMIT:
    raise SearchError(
      f"--limit cannot exceed the hard ceiling {HARD_RESULT_LIMIT:,}"
    )
  if args.print0 and args.format != "paths":
    raise SearchError("--print0 requires --format paths")

  positive = any(
    (
      args.name,
      args.ext,
      args.glob,
      args.exact,
      args.names_from,
      args.content,
    )
  )
  if not positive and not args.all:
    raise SearchError(
      "refusing an unfiltered search; add a selector or explicitly use --all"
    )

  guarded = [
    ("--name", term, False) for term in args.name
  ] + [
    ("--exclude-name", term, False) for term in args.exclude_name
  ] + [
    ("--content", term, args.content_regex) for term in args.content
  ] + [
    ("--exclude-content", term, args.content_regex)
    for term in args.exclude_content
  ]
  for option, term, regex_mode in guarded:
    if meaningful_length(term, regex_mode) < args.min_term_length:
      raise SearchError(
        f"{option} term {term!r} is shorter than --min-term-length "
        f"{args.min_term_length}"
      )


def normalise_roots(values: Sequence[str]) -> list[Path]:
  """Expand and validate root paths."""

  roots: list[Path] = []
  for raw in values or ["."]:
    root = Path(raw).expanduser().absolute()
    if not root.exists():
      raise SearchError(f"search root does not exist: {root}")
    if not root.is_dir():
      raise SearchError(f"search root is not a directory: {root}")
    roots.append(root)
  return roots


def normalise_ext(value: str, case_sensitive: bool) -> str:
  """Normalise an extension while supporting compound values."""

  ext = value.strip().lstrip(".")
  if not ext:
    raise SearchError("an extension cannot be empty")
  return ext if case_sensitive else ext.casefold()


def collect_reference_names(
  directories: Sequence[Path],
  recursive: bool,
  case_sensitive: bool,
) -> tuple[set[str], list[Path]]:
  """Collect exact basenames from reference directories."""

  names: set[str] = set()
  sources: list[Path] = []
  for supplied in directories:
    source = supplied.expanduser().absolute()
    if not source.is_dir():
      raise SearchError(f"--names-from is not a directory: {source}")
    sources.append(source)
    iterator: Iterable[Path]
    iterator = source.rglob("*") if recursive else source.iterdir()
    try:
      for item in iterator:
        if item.is_file():
          name = item.name if case_sensitive else item.name.casefold()
          names.add(name)
    except OSError as exc:
      raise SearchError(f"cannot read --names-from {source}: {exc}") from exc
  if directories and not names:
    raise SearchError("the --names-from directories contain no files")
  return names, sources


def compile_matchers(
  terms: Sequence[str],
  regex_mode: bool,
  whole_word: bool,
  case_sensitive: bool,
) -> list[TermMatcher]:
  """Compile literal or regular-expression content matchers."""

  flags = re.MULTILINE
  if not case_sensitive:
    flags |= re.IGNORECASE
  compiled: list[TermMatcher] = []
  for term in terms:
    pattern = term if regex_mode else re.escape(term)
    if whole_word:
      pattern = rf"(?<!\w)(?:{pattern})(?!\w)"
    try:
      compiled.append(TermMatcher(term, re.compile(pattern, flags)))
    except re.error as exc:
      raise SearchError(f"invalid content regex {term!r}: {exc}") from exc
  return compiled


def folded(value: str, case_sensitive: bool) -> str:
  """Return *value* in the selected case-matching form."""

  return value if case_sensitive else value.casefold()


def glob_matches(
  pattern: str,
  name: str,
  relative: str,
  case_sensitive: bool,
) -> bool:
  """Match basename globs or relative-path globs containing a slash."""

  target = relative if "/" in pattern else name
  if not case_sensitive:
    pattern = pattern.casefold()
    target = target.casefold()
  return fnmatch.fnmatchcase(target, pattern)


def has_extension(name: str, extension: str, case_sensitive: bool) -> bool:
  """Return whether *name* has a simple or compound extension."""

  candidate = name if case_sensitive else name.casefold()
  return candidate.endswith(f".{extension}")


def directory_is_excluded(
  relative_dir: str,
  patterns: Sequence[str],
  case_sensitive: bool,
) -> bool:
  """Check every directory component against exclusion globs."""

  components = Path(relative_dir).parts
  for component in components:
    for pattern in patterns:
      left = component if case_sensitive else component.casefold()
      right = pattern if case_sensitive else pattern.casefold()
      if fnmatch.fnmatchcase(left, right):
        return True
  return False


def within(path: Path, directory: Path) -> bool:
  """Return whether *path* is equal to or located below *directory*."""

  try:
    path.relative_to(directory)
  except ValueError:
    return False
  return True


def walk_files(
  roots: Sequence[Path],
  args: argparse.Namespace,
  stats: SearchStats,
) -> Iterator[tuple[Path, Path, str]]:
  """Yield unique files as ``(path, root, relative_posix_path)``."""

  seen_files: set[str] = set()
  seen_directories: set[tuple[int, int]] = set()

  def on_error(exc: OSError) -> None:
    stats.unreadable += 1
    print(f"{PROGRAM}: warning: {exc}", file=sys.stderr)

  for root in roots:
    for dirpath_raw, dirnames, filenames in os.walk(
      root,
      topdown=True,
      onerror=on_error,
      followlinks=args.follow,
    ):
      dirpath = Path(dirpath_raw)
      relative_dir = dirpath.relative_to(root)
      relative_parts = () if relative_dir == Path(".") else relative_dir.parts
      current_depth = len(relative_parts)

      if args.follow:
        try:
          info = dirpath.stat()
        except OSError:
          stats.unreadable += 1
          dirnames[:] = []
          continue
        inode = (info.st_dev, info.st_ino)
        if inode in seen_directories:
          dirnames[:] = []
          continue
        seen_directories.add(inode)

      kept_dirs: list[str] = []
      for dirname in dirnames:
        if not args.hidden and dirname.startswith("."):
          continue
        relative_child = Path(*relative_parts, dirname).as_posix()
        if directory_is_excluded(
          relative_child,
          args.exclude_dir,
          args.case_sensitive,
        ):
          continue
        kept_dirs.append(dirname)
      dirnames[:] = kept_dirs

      if args.max_depth is not None and current_depth >= args.max_depth:
        dirnames[:] = []

      for filename in filenames:
        if not args.hidden and filename.startswith("."):
          continue
        file_depth = current_depth + 1
        if args.max_depth is not None and file_depth > args.max_depth:
          continue

        path = dirpath / filename
        try:
          mode = path.stat(follow_symlinks=args.follow).st_mode
        except OSError:
          stats.unreadable += 1
          continue
        if not stat.S_ISREG(mode):
          continue

        stats.visited += 1
        if stats.visited > args.scan_limit:
          raise SearchError(
            f"scan limit {args.scan_limit:,} exceeded; narrow the root or "
            "raise --scan-limit within the hard ceiling"
          )

        absolute_key = os.path.abspath(os.fspath(path))
        if absolute_key in seen_files:
          continue
        seen_files.add(absolute_key)
        relative = path.relative_to(root).as_posix()
        yield path, root, relative


def make_candidate(
  path: Path,
  root: Path,
  relative: str,
  args: argparse.Namespace,
  exact_names: set[str],
  sources: Sequence[Path],
  extensions: Sequence[str],
  excluded_extensions: Sequence[str],
) -> Candidate | None:
  """Apply path/name selectors and return a scored candidate."""

  name = path.name
  comparable_name = folded(name, args.case_sensitive)

  if args.exclude_source and any(within(path, source) for source in sources):
    return None
  if any(
    folded(term, args.case_sensitive) in comparable_name
    for term in args.exclude_name
  ):
    return None
  if any(
    has_extension(name, ext, args.case_sensitive)
    for ext in excluded_extensions
  ):
    return None
  if any(
    glob_matches(pattern, name, relative, args.case_sensitive)
    for pattern in args.exclude_glob
  ):
    return None

  score = 0.0
  if exact_names:
    if comparable_name not in exact_names:
      return None
    score += args.weight_exact

  if extensions:
    if not any(
      has_extension(name, extension, args.case_sensitive)
      for extension in extensions
    ):
      return None
    score += args.weight_ext

  if args.glob:
    glob_hits = sum(
      glob_matches(pattern, name, relative, args.case_sensitive)
      for pattern in args.glob
    )
    if not glob_hits:
      return None
    score += args.weight_glob * glob_hits

  if args.name:
    name_counts = [
      comparable_name.count(folded(term, args.case_sensitive))
      for term in args.name
    ]
    accepted = (
      any(name_counts)
      if args.name_mode == "any"
      else all(count > 0 for count in name_counts)
    )
    if not accepted:
      return None
    score += args.weight_name * sum(name_counts)

  try:
    info = path.stat()
  except OSError:
    return None
  return Candidate(
    path=path,
    root=root,
    relative=relative,
    size=info.st_size,
    mtime=info.st_mtime,
    score=score,
  )


def inspect_content(
  candidate: Candidate,
  positive: Sequence[TermMatcher],
  excluded: Sequence[TermMatcher],
  args: argparse.Namespace,
) -> tuple[Result | None, str | None]:
  """Read one candidate and apply all content predicates."""

  if candidate.size > args.max_file_size:
    return None, "too_large"
  try:
    data = candidate.path.read_bytes()
  except OSError:
    return None, "unreadable"
  if not args.binary_text and b"\0" in data[:8192]:
    return None, "binary"
  try:
    text = data.decode(args.encoding, errors="replace")
  except LookupError as exc:
    raise SearchError(f"unknown text encoding: {args.encoding}") from exc

  if any(matcher.count(text) > 0 for matcher in excluded):
    return None, None
  counts = [matcher.count(text) for matcher in positive]
  if positive:
    accepted = (
      any(counts)
      if args.content_mode == "any"
      else all(count > 0 for count in counts)
    )
    if not accepted:
      return None, None
  hits = sum(counts)
  return Result(
    path=candidate.path,
    root=candidate.root,
    relative=candidate.relative,
    size=candidate.size,
    mtime=candidate.mtime,
    score=candidate.score + args.weight_content * hits,
    hits=hits,
  ), None


def search(args: argparse.Namespace) -> tuple[list[Result], SearchStats]:
  """Execute the complete search and return matches plus counters."""

  roots = normalise_roots(args.roots)
  reference_names, sources = collect_reference_names(
    args.names_from,
    args.names_from_recursive,
    args.case_sensitive,
  )
  explicit_names = {
    folded(name, args.case_sensitive) for name in args.exact
  }
  exact_names = reference_names | explicit_names
  extensions = [
    normalise_ext(ext, args.case_sensitive) for ext in args.ext
  ]
  excluded_extensions = [
    normalise_ext(ext, args.case_sensitive) for ext in args.exclude_ext
  ]
  positive_content = compile_matchers(
    args.content,
    args.content_regex,
    args.word,
    args.case_sensitive,
  )
  excluded_content = compile_matchers(
    args.exclude_content,
    args.content_regex,
    args.word,
    args.case_sensitive,
  )

  stats = SearchStats()
  candidates: list[Candidate] = []
  for path, root, relative in walk_files(roots, args, stats):
    candidate = make_candidate(
      path,
      root,
      relative,
      args,
      exact_names,
      sources,
      extensions,
      excluded_extensions,
    )
    if candidate is not None:
      candidates.append(candidate)
  stats.candidates = len(candidates)

  needs_content = bool(positive_content or excluded_content)
  if not needs_content:
    results = [
      Result(
        path=item.path,
        root=item.root,
        relative=item.relative,
        size=item.size,
        mtime=item.mtime,
        score=item.score,
        hits=0,
      )
      for item in candidates
    ]
  else:
    results = []
    worker = functools.partial(
      inspect_content,
      positive=positive_content,
      excluded=excluded_content,
      args=args,
    )
    with concurrent.futures.ThreadPoolExecutor(
      max_workers=args.jobs,
      thread_name_prefix=PROGRAM,
    ) as pool:
      for result, reason in pool.map(worker, candidates):
        if result is not None:
          results.append(result)
        elif reason == "unreadable":
          stats.unreadable += 1
        elif reason == "binary":
          stats.binary += 1
        elif reason == "too_large":
          stats.too_large += 1

  stats.matched = len(results)
  sort_results(results, args.sort, args.reverse)
  return results, stats


def sort_results(results: list[Result], key_name: str, reverse: bool) -> None:
  """Sort in a documented natural direction, with paths as stable ties."""

  results.sort(key=lambda item: os.fspath(item.path).casefold())
  selectors = {
    "score": (lambda item: item.score, True),
    "hits": (lambda item: item.hits, True),
    "name": (lambda item: item.path.name.casefold(), False),
    "path": (lambda item: os.fspath(item.path).casefold(), False),
    "size": (lambda item: item.size, True),
    "mtime": (lambda item: item.mtime, True),
  }
  selector, naturally_descending = selectors[key_name]
  results.sort(
    key=selector,
    reverse=naturally_descending ^ reverse,
  )


def human_size(size: int) -> str:
  """Render an IEC byte size compactly."""

  value = float(size)
  for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
    if abs(value) < 1024 or unit == "TiB":
      return f"{value:.0f} {unit}" if unit == "B" else f"{value:.1f} {unit}"
    value /= 1024
  return f"{value:.1f} PiB"


def modified_time(timestamp: float) -> str:
  """Render a timestamp in the machine's local timezone."""

  moment = dt.datetime.fromtimestamp(timestamp).astimezone()
  return moment.strftime("%Y-%m-%d %H:%M")


def score_ratio(
  score: float,
  scores: Sequence[float],
  gradient: str,
  maximum: float,
) -> float:
  """Map a score to [0, 1] using relative or fixed scaling."""

  if gradient == "fixed":
    return max(0.0, min(1.0, score / maximum))
  low = min(scores)
  high = max(scores)
  if math.isclose(low, high):
    return 0.5
  return (score - low) / (high - low)


def gradient_colour(ratio: float) -> str:
  """Interpolate red -> yellow -> green and return a Rich colour."""

  red = (255, 95, 95)
  yellow = (255, 215, 95)
  green = (95, 255, 135)
  if ratio <= 0.5:
    local = ratio * 2
    start, end = red, yellow
  else:
    local = (ratio - 0.5) * 2
    start, end = yellow, green
  rgb = tuple(
    round(left + (right - left) * local)
    for left, right in zip(start, end)
  )
  return f"rgb({rgb[0]},{rgb[1]},{rgb[2]})"


def print_table(
  results: Sequence[Result],
  stats: SearchStats,
  args: argparse.Namespace,
) -> None:
  """Print a Rich table, falling back to a plain table if unavailable."""

  try:
    from rich.console import Console
    from rich.table import Table
  except ImportError:
    print_plain(results, stats, args)
    print(
      f"{PROGRAM}: note: install python-rich for gradient table output",
      file=sys.stderr,
    )
    return

  force_terminal: bool | None
  if args.color == "always":
    force_terminal = True
  elif args.color == "never" or os.environ.get("NO_COLOR") is not None:
    force_terminal = False
  else:
    force_terminal = None
  console = Console(force_terminal=force_terminal)
  table = Table(show_header=True, header_style="bold cyan", box=None)
  table.add_column("#", justify="right", style="dim")
  table.add_column("Score", justify="right")
  table.add_column("Hits", justify="right")
  table.add_column("Size", justify="right")
  table.add_column("Modified", no_wrap=True)
  table.add_column("Name", no_wrap=True)
  table.add_column("Directory", overflow="fold")

  scores = [result.score for result in results] or [0.0]
  for rank, result in enumerate(results, start=1):
    ratio = score_ratio(
      result.score,
      scores,
      args.gradient,
      args.gradient_max,
    )
    style = gradient_colour(ratio)
    table.add_row(
      str(rank),
      f"{result.score:.1f}",
      str(result.hits),
      human_size(result.size),
      modified_time(result.mtime),
      result.path.name,
      os.fspath(result.path.parent),
      style=style,
    )
  console.print(table)
  if not args.no_summary:
    console.print(summary_text(len(results), stats), style="dim")


def print_plain(
  results: Sequence[Result],
  stats: SearchStats,
  args: argparse.Namespace,
) -> None:
  """Print an escaped tab-separated table."""

  print("rank\tscore\thits\tsize\tmodified\tpath")
  for rank, result in enumerate(results, start=1):
    fields = (
      str(rank),
      f"{result.score:.1f}",
      str(result.hits),
      str(result.size),
      modified_time(result.mtime),
      os.fspath(result.path),
    )
    print("\t".join(json.dumps(field)[1:-1] for field in fields))
  if not args.no_summary:
    print(summary_text(len(results), stats), file=sys.stderr)


def print_json(
  results: Sequence[Result],
  stats: SearchStats,
  args: argparse.Namespace,
) -> None:
  """Print one JSON object with metadata and ordered results."""

  payload = {
    "program": PROGRAM,
    "version": VERSION,
    "sort": args.sort,
    "shown": len(results),
    "matched": stats.matched,
    "stats": dataclasses.asdict(stats),
    "results": [
      {
        "rank": rank,
        "score": result.score,
        "content_hits": result.hits,
        "size_bytes": result.size,
        "modified_unix": result.mtime,
        "name": result.path.name,
        "path": os.fspath(result.path),
        "root": os.fspath(result.root),
        "relative_path": result.relative,
      }
      for rank, result in enumerate(results, start=1)
    ],
  }
  json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
  sys.stdout.write("\n")


def print_paths(results: Sequence[Result], print0: bool) -> None:
  """Print paths with newline or NUL termination."""

  separator = "\0" if print0 else "\n"
  for result in results:
    sys.stdout.write(os.fspath(result.path))
    sys.stdout.write(separator)


def summary_text(shown: int, stats: SearchStats) -> str:
  """Construct a compact human-readable search summary."""

  parts = [
    f"showing {shown:,} of {stats.matched:,} matches",
    f"visited {stats.visited:,} files",
    f"path candidates {stats.candidates:,}",
  ]
  skipped = stats.unreadable + stats.binary + stats.too_large
  if skipped:
    parts.append(
      "skipped "
      f"{skipped:,} ({stats.unreadable:,} unreadable, "
      f"{stats.binary:,} binary, {stats.too_large:,} too large)"
    )
  return "; ".join(parts)


def emit(
  results: list[Result],
  stats: SearchStats,
  args: argparse.Namespace,
) -> None:
  """Limit and print results in the requested representation."""

  shown = results[: args.limit]
  if args.format == "table":
    print_table(shown, stats, args)
  elif args.format == "plain":
    print_plain(shown, stats, args)
  elif args.format == "json":
    print_json(shown, stats, args)
  else:
    print_paths(shown, args.print0)


def main(argv: Sequence[str] | None = None) -> int:
  """Program entry point."""

  parser = build_parser()
  args = parser.parse_args(argv)
  try:
    validate_args(args)
    results, stats = search(args)
    emit(results, stats, args)
  except SearchError as exc:
    print(f"{PROGRAM}: error: {exc}", file=sys.stderr)
    return 2
  except KeyboardInterrupt:
    print(f"\n{PROGRAM}: interrupted", file=sys.stderr)
    return 130
  return 0 if stats.matched else 1


if __name__ == "__main__":
  raise SystemExit(main())
