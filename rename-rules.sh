from pathlib import Path
import subprocess
import textwrap

script = r'''#!/usr/bin/env python3
"""
rename-rules

Safely rename files and/or directories according to conservative rules.

Default behaviour:
  - dry-run only; no changes are made unless --apply is given
  - strip literal matching outer single/double quotes
  - strip literal matching quotes around the stem, e.g. "'file'.pdf"
  - replace whitespace runs with "_"
  - skip unchanged names
  - skip collisions unless --overwrite is explicitly given

Examples:
  rename-rules ~/Downloads
  rename-rules ~/Downloads --apply
  rename-rules ~/Downloads --recursive --include-dirs --apply
  rename-rules ~/Downloads --spaces "-" --apply
  rename-rules ~/Downloads --no-spaces --apply
  rename-rules ~/Downloads --glob "* *" --apply
  rename-rules ~/Downloads --interactive --apply
"""

from __future__ import annotations

import argparse
import fnmatch
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class RenamePlan:
  source: Path
  destination: Path


def parse_args() -> argparse.Namespace:
  parser = argparse.ArgumentParser(
    prog="rename-rules",
    formatter_class=argparse.RawDescriptionHelpFormatter,
    description=(
      "Safely rename files/directories by stripping literal quote wrappers "
      "and replacing whitespace with a chosen replacement."
    ),
    epilog="""
Examples:
  rename-rules ~/Downloads
  rename-rules ~/Downloads --apply
  rename-rules ~/Downloads --recursive --include-dirs --apply
  rename-rules ~/Downloads --spaces "_" --apply
  rename-rules ~/Downloads --spaces "-" --apply
  rename-rules ~/Downloads --no-spaces --apply
  rename-rules ~/Downloads --glob "* *" --apply
  rename-rules ~/Downloads --interactive --apply
"""
  )

  parser.add_argument(
    "targets",
    nargs="+",
    help="Files and/or directories to inspect."
  )

  parser.add_argument(
    "-a", "--apply",
    action="store_true",
    help="Actually rename files. Without this, only print a dry-run plan."
  )

  parser.add_argument(
    "-r", "--recursive",
    action="store_true",
    help="Recurse into target directories."
  )

  parser.add_argument(
    "-d", "--include-dirs",
    action="store_true",
    help="Also rename directories, not only files."
  )

  parser.add_argument(
    "--self",
    action="store_true",
    help="Also consider explicitly supplied directory targets themselves."
  )

  parser.add_argument(
    "--hidden",
    action="store_true",
    help="Include hidden files/directories whose names begin with '.'."
  )

  parser.add_argument(
    "--glob",
    action="append",
    default=[],
    metavar="PATTERN",
    help="Only process names matching this shell glob. Can be repeated."
  )

  parser.add_argument(
    "--regex",
    action="append",
    default=[],
    metavar="REGEX",
    help="Only process names matching this Python regex. Can be repeated."
  )

  parser.add_argument(
    "--spaces",
    default="_",
    metavar="TEXT",
    help="Replacement for whitespace runs. Default: '_'."
  )

  parser.add_argument(
    "--no-spaces",
    action="store_true",
    help="Do not replace spaces/whitespace."
  )

  parser.add_argument(
    "--no-strip-quotes",
    action="store_true",
    help="Do not strip literal outer single/double quote wrappers."
  )

  parser.add_argument(
    "--no-trim",
    action="store_true",
    help="Do not trim leading/trailing whitespace before applying rules."
  )

  parser.add_argument(
    "--no-squeeze",
    action="store_true",
    help="Do not collapse repeated replacement runs."
  )

  parser.add_argument(
    "--lower",
    action="store_true",
    help="Lowercase names after other rules."
  )

  parser.add_argument(
    "-i", "--interactive",
    action="store_true",
    help="Ask before each rename. Only meaningful with --apply."
  )

  parser.add_argument(
    "--overwrite",
    action="store_true",
    help="Allow overwriting existing destination paths. Dangerous."
  )

  parser.add_argument(
    "-q", "--quiet",
    action="store_true",
    help="Only print warnings/errors."
  )

  return parser.parse_args()


def is_hidden(path: Path) -> bool:
  return path.name.startswith(".")


def has_filter_match(name: str, args: argparse.Namespace) -> bool:
  if args.glob:
    if not any(fnmatch.fnmatchcase(name, pattern) for pattern in args.glob):
      return False

  if args.regex:
    if not any(re.search(pattern, name) for pattern in args.regex):
      return False

  return True


def strip_matching_quote_wrappers(name: str) -> str:
  """
  Strip literal matching quote wrappers.

  Supported forms:
    "'file name.pdf'" -> "file name.pdf"
    "'file name'.pdf" -> "file name.pdf"
    '"file name.pdf"' -> "file name.pdf"
    '"file name".pdf' -> "file name.pdf"

  Unmatched quotes are intentionally preserved.
  """
  previous = None
  current = name

  while previous != current:
    previous = current

    for quote in ("'", '"'):
      if len(current) >= 2 and current[0] == quote and current[-1] == quote:
        current = current[1:-1]
        continue

      suffix = Path(current).suffix
      if not suffix:
        continue

      stem = current[:-len(suffix)]

      if len(stem) >= 2 and stem[0] == quote and stem[-1] == quote:
        current = stem[1:-1] + suffix

  return current


def squeeze_replacement_runs(name: str, replacement: str) -> str:
  if replacement == "":
    return name

  escaped = re.escape(replacement)
  return re.sub(f"(?:{escaped})+", replacement, name)


def transform_name(name: str, args: argparse.Namespace) -> str:
  new_name = name

  if not args.no_trim:
    new_name = new_name.strip()

  if not args.no_strip_quotes:
    new_name = strip_matching_quote_wrappers(new_name)

  if not args.no_trim:
    new_name = new_name.strip()

  if not args.no_spaces:
    if args.no_squeeze:
      new_name = new_name.replace(" ", args.spaces)
    else:
      new_name = re.sub(r"\s+", args.spaces, new_name)
      new_name = squeeze_replacement_runs(new_name, args.spaces)

  if args.lower:
    new_name = new_name.lower()

  return new_name


def collect_from_directory(root: Path, args: argparse.Namespace) -> list[Path]:
  candidates: list[Path] = []

  if args.recursive:
    for dirpath, dirnames, filenames in os.walk(root):
      current_dir = Path(dirpath)

      if not args.hidden:
        dirnames[:] = [name for name in dirnames if not name.startswith(".")]
        filenames = [name for name in filenames if not name.startswith(".")]

      for filename in filenames:
        candidates.append(current_dir / filename)

      if args.include_dirs:
        for dirname in dirnames:
          candidates.append(current_dir / dirname)

  else:
    for child in root.iterdir():
      if not args.hidden and is_hidden(child):
        continue

      if child.is_dir():
        if args.include_dirs:
          candidates.append(child)
      else:
        candidates.append(child)

  if args.self and args.include_dirs:
    candidates.append(root)

  return candidates


def collect_candidates(args: argparse.Namespace) -> list[Path]:
  candidates: list[Path] = []

  for raw_target in args.targets:
    target = Path(raw_target).expanduser()

    if not target.exists() and not target.is_symlink():
      print(f"Warning: target does not exist: {target}", file=sys.stderr)
      continue

    if not args.hidden and is_hidden(target):
      continue

    if target.is_dir():
      candidates.extend(collect_from_directory(target, args))
    else:
      candidates.append(target)

  filtered = [
    path for path in candidates
    if has_filter_match(path.name, args)
  ]

  # Deepest paths first prevents recursive directory renames from breaking
  # still-pending child paths.
  filtered.sort(key=lambda path: len(path.parts), reverse=True)

  return filtered


def build_plan(args: argparse.Namespace) -> list[RenamePlan]:
  plan: list[RenamePlan] = []
  seen_destinations: set[Path] = set()

  for source in collect_candidates(args):
    new_name = transform_name(source.name, args)

    if new_name == source.name:
      continue

    if new_name in ("", ".", ".."):
      print(
        f"Warning: skipped unsafe empty/special result for: {source}",
        file=sys.stderr
      )
      continue

    destination = source.with_name(new_name)

    if destination in seen_destinations:
      print(
        f"Warning: skipped duplicate destination: {source} -> {destination}",
        file=sys.stderr
      )
      continue

    seen_destinations.add(destination)
    plan.append(RenamePlan(source=source, destination=destination))

  return plan


def confirm(plan: RenamePlan) -> bool:
  answer = input(f"Rename?\n  {plan.source}\n  -> {plan.destination}\n[y/N] ")
  return answer.lower() in {"y", "yes"}


def print_plan(plan: list[RenamePlan], args: argparse.Namespace) -> None:
  if args.quiet:
    return

  if not plan:
    print("No matching rename operations.")
    return

  header = "Planned renames:" if not args.apply else "Renames:"
  print(header)

  for item in plan:
    print(f"  {item.source}")
    print(f"    -> {item.destination}")


def apply_plan(plan: list[RenamePlan], args: argparse.Namespace) -> int:
  failures = 0

  for item in plan:
    if args.interactive and not confirm(item):
      continue

    if item.destination.exists() and not args.overwrite:
      print(
        f"Warning: destination exists; skipped: {item.destination}",
        file=sys.stderr
      )
      failures += 1
      continue

    try:
      item.source.rename(item.destination)
    except OSError as exc:
      print(f"Error: failed to rename {item.source}: {exc}", file=sys.stderr)
      failures += 1

  return failures


def main() -> int:
  args = parse_args()
  plan = build_plan(args)

  print_plan(plan, args)

  if not args.apply:
    if plan and not args.quiet:
      print("\nDry-run only. Add --apply to perform these renames.")
    return 0

  return 1 if apply_plan(plan, args) else 0


if __name__ == "__main__":
  raise SystemExit(main())
'''

out = Path("/mnt/data/rename-rules")
out.write_text(script, encoding="utf-8")
out.chmod(0o755)

result = subprocess.run(
    [str(out), "--help"],
    check=True,
    text=True,
    capture_output=True
)

print(f"Wrote: {out}")
print(f"Executable: {oct(out.stat().st_mode & 0o777)}")
print("First line:", out.read_text(encoding="utf-8").splitlines()[0])
print("\nHelp smoke-test:")
print("\n".join(result.stdout.splitlines()[:12]))

