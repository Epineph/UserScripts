#!/usr/bin/env python3

"""
tree2fs.py

Create a directory/file structure from an ASCII/Unicode tree listing such as:

jobindex-scraper/
├── .gitignore
├── README.md
├── pyproject.toml
├── requirements-dev.txt
├── data/
│   ├── input/
│   │   └── keywords.txt
│   ├── output/
│   ├── logs/
│   └── state/
│       └── .gitkeep
├── src/
│   └── jobindex_scraper/
│       ├── __init__.py
│       ├── cli.py
│       ├── paths.py
│       ├── logging_utils.py
│       ├── auth.py
│       ├── scraper.py
│       ├── extract.py
│       ├── export.py
│       └── models.py
├── tests/
│   └── test_smoke.py
└── scripts/
    └── bootstrap.sh

The script infers hierarchy from indentation and tree markers.

Rules
-----
- Entries ending in '/' are created as directories.
- Other entries are created as files.
- The first line is treated as the root path unless --strip-root is used.
- Existing paths are left untouched unless --force-files is used.

Examples
--------
python tree2fs.py --input table
python tree2fs.py --input table --dry-run
python tree2fs.py --input table --base-dir ~/repos
python tree2fs.py --input table --strip-root
python tree2fs.py --input table --force-files
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


TREE_TOKEN_RE = re.compile(r"^[├└]──\s")


def parse_args() -> argparse.Namespace:
  parser = argparse.ArgumentParser(
    description=(
      "Create directories and files from a tree-style text description."
    )
  )

  parser.add_argument(
    "--input",
    "-i",
    required=True,
    help="Path to input file containing the tree text.",
  )

  parser.add_argument(
    "--base-dir",
    "-b",
    default=".",
    help=(
      "Base directory under which the structure is created. "
      "Default: current directory."
    ),
  )

  parser.add_argument(
    "--dry-run",
    action="store_true",
    help="Print planned actions without creating anything.",
  )

  parser.add_argument(
    "--strip-root",
    action="store_true",
    help=(
      "Ignore the first tree line as a created root directory and create its "
      "children directly under --base-dir."
    ),
  )

  parser.add_argument(
    "--force-files",
    action="store_true",
    help=(
      "Overwrite existing files by truncating them to empty. "
      "Directories are never removed."
    ),
  )

  return parser.parse_args()


def classify_line(raw_line: str) -> tuple[int, str]:
  """
  Parse one tree line.

  Returns
  -------
  tuple[int, str]
      (depth, name)

  Depth is:
    0 for root line
    1 for direct children of root
    2 for grandchildren
    etc.

  The parser assumes a standard tree layout where each indentation unit is
  represented by either:
    '│   '  or  '    '

  followed by:
    '├── '  or  '└── '
  """
  line = raw_line.rstrip("\n")

  if not line.strip():
    raise ValueError("Blank lines are not allowed inside the tree block.")

  if "── " not in line:
    return 0, line.strip()

  idx = line.find("├── ")
  if idx == -1:
    idx = line.find("└── ")

  if idx == -1:
    raise ValueError(f"Could not locate tree marker in line: {line!r}")

  prefix = line[:idx]
  name = line[idx + 4:].strip()

  if not name:
    raise ValueError(f"Missing entry name in line: {line!r}")

  if len(prefix) % 4 != 0:
    raise ValueError(
      f"Indentation prefix length is not divisible by 4 in line: {line!r}"
    )

  depth = (len(prefix) // 4) + 1
  return depth, name


def create_dir(path: Path, dry_run: bool) -> None:
  if dry_run:
    print(f"mkdir -p {path}")
    return
  path.mkdir(parents=True, exist_ok=True)


def create_file(path: Path, dry_run: bool, force_files: bool) -> None:
  if dry_run:
    if force_files:
      print(f": > {path}")
    else:
      print(f"touch {path}")
    return

  path.parent.mkdir(parents=True, exist_ok=True)

  if force_files:
    path.write_text("", encoding="utf-8")
  else:
    path.touch(exist_ok=True)


def main() -> int:
  args = parse_args()

  input_path = Path(args.input).expanduser().resolve()
  base_dir = Path(args.base_dir).expanduser().resolve()

  if not input_path.is_file():
    print(f"Error: input file not found: {input_path}", file=sys.stderr)
    return 1

  lines = input_path.read_text(encoding="utf-8").splitlines()
  lines = [line.rstrip() for line in lines if line.strip()]

  if not lines:
    print("Error: input file is empty.", file=sys.stderr)
    return 1

  parsed: list[tuple[int, str]] = [classify_line(line) for line in lines]

  root_depth, root_name = parsed[0]
  if root_depth != 0:
    print(
      "Error: first line must be the root entry without tree markers.",
      file=sys.stderr,
    )
    return 1

  if args.strip_root:
    root_path = base_dir
  else:
    root_is_dir = root_name.endswith("/")
    root_clean = root_name[:-1] if root_is_dir else root_name

    if not root_is_dir:
      print(
        "Error: root entry should end with '/' unless --strip-root is used.",
        file=sys.stderr,
      )
      return 1

    root_path = base_dir / root_clean

    create_dir(root_path, args.dry_run)

  stack: list[Path] = [root_path]

  for depth, name in parsed[1:]:
    is_dir = name.endswith("/")
    clean_name = name[:-1] if is_dir else name

    if not clean_name:
      print(
        f"Error: invalid empty name derived from entry: {name!r}",
        file=sys.stderr,
      )
      return 1

    while len(stack) > depth:
      stack.pop()

    if len(stack) != depth:
      print(
        (
          "Error: inconsistent indentation hierarchy encountered at entry "
          f"{name!r}. Expected stack length {depth}, got {len(stack)}."
        ),
        file=sys.stderr,
      )
      return 1

    parent = stack[-1]
    current = parent / clean_name

    if is_dir:
      create_dir(current, args.dry_run)
      stack.append(current)
    else:
      create_file(current, args.dry_run, args.force_files)

  return 0


if __name__ == "__main__":
  raise SystemExit(main())
