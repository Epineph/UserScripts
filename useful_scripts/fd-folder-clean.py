#!/usr/bin/env python3
"""
Find folders associated with fd matches, show their recursive size, and
optionally delete selected folders recursively with conservative safeguards.
"""

from __future__ import annotations

import argparse
import os
import shutil
import stat
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

try:
  from rich.console import Console
  from rich.table import Table
  from rich.text import Text

  HAVE_RICH = True
  CONSOLE = Console()
except ImportError:
  HAVE_RICH = False
  CONSOLE = None


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class Candidate:
  """Deletion candidate derived from fd matches."""

  path: Path
  matched_files: int = 0
  matched_dirs: int = 0
  raw_matches: list[Path] = field(default_factory=list)
  total_files: int = 0
  total_bytes: int = 0
  scan_errors: int = 0
  needs_sudo: bool = False
  blocked_reason: str = ""
  index: int = 0

  @property
  def reason(self) -> str:
    """Return a concise explanation of why this folder is listed."""
    parts: list[str] = []

    if self.matched_dirs:
      parts.append(f"folder matched ({self.matched_dirs})")

    if self.matched_files:
      parts.append(f"contains matching files ({self.matched_files})")

    return " + ".join(parts) if parts else "unknown"

  @property
  def fd_matches(self) -> int:
    """Return total fd matches contributing to this candidate."""
    return self.matched_files + self.matched_dirs


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

def print_msg(message: str, *, style: str | None = None) -> None:
  """Print through Rich when available, otherwise plain print."""
  if HAVE_RICH and CONSOLE is not None:
    CONSOLE.print(message, style=style)
  else:
    print(strip_rich_markup(message))


def strip_rich_markup(text: str) -> str:
  """Remove the small amount of Rich markup used by this script."""
  replacements = {
    "[bold]": "",
    "[/bold]": "",
    "[green]": "",
    "[/green]": "",
    "[yellow]": "",
    "[/yellow]": "",
    "[red]": "",
    "[/red]": "",
    "[cyan]": "",
    "[/cyan]": "",
    "[dim]": "",
    "[/dim]": "",
  }

  for old, new in replacements.items():
    text = text.replace(old, new)

  return text


def human_bytes(num_bytes: int) -> str:
  """Convert a byte count to a compact human-readable string."""
  units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
  value = float(num_bytes)

  for unit in units:
    if abs(value) < 1024.0 or unit == units[-1]:
      return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
    value /= 1024.0

  return f"{num_bytes} B"


# ---------------------------------------------------------------------------
# Path and permission helpers
# ---------------------------------------------------------------------------

def resolve_path(path: str | Path) -> Path:
  """Expand and resolve a path without requiring every component to exist."""
  return Path(path).expanduser().resolve(strict=False)


def path_is_relative_to(path: Path, base: Path) -> bool:
  """Return True if path is equal to or below base."""
  try:
    path.relative_to(base)
    return True
  except ValueError:
    return False


def is_dir_no_follow(path: Path) -> bool:
  """Return True if path itself is a directory, not a directory symlink."""
  try:
    return stat.S_ISDIR(path.lstat().st_mode)
  except OSError:
    return False


def is_symlink(path: Path) -> bool:
  """Return True if path itself is a symbolic link."""
  try:
    return stat.S_ISLNK(path.lstat().st_mode)
  except OSError:
    return False


def deletion_block_reason(path: Path, search_root: Path) -> str:
  """Return a reason why a candidate must never be deleted by this script."""
  root = Path("/").resolve()
  home = Path.home().resolve(strict=False)
  path = path.resolve(strict=False)
  search_root = search_root.resolve(strict=False)

  if path == root:
    return "refusing to delete /"

  if path.parent == root:
    return "refusing to delete root-level directories"

  if path == home:
    return "refusing to delete the home directory itself"

  if path == search_root:
    return "refusing to delete the search root itself"

  if is_symlink(path):
    return "refusing to delete a symlink candidate"

  return ""


def scan_tree(path: Path) -> tuple[int, int, int, bool]:
  """
  Count files and bytes under path, and estimate whether sudo is needed.

  Deleting a directory requires write and execute permission on the target
  directory, its subdirectories, and the parent directory containing the target.
  """
  file_count = 0
  total_bytes = 0
  errors = 0
  needs_sudo = False

  if os.geteuid() != 0:
    if not os.access(path.parent, os.W_OK | os.X_OK):
      needs_sudo = True

    if not os.access(path, os.R_OK | os.W_OK | os.X_OK):
      needs_sudo = True

  stack = [path]

  while stack:
    current = stack.pop()

    if os.geteuid() != 0 and not os.access(current, os.W_OK | os.X_OK):
      needs_sudo = True

    try:
      with os.scandir(current) as iterator:
        for entry in iterator:
          try:
            entry_path = Path(entry.path)
            entry_stat = entry.stat(follow_symlinks=False)

            if entry.is_dir(follow_symlinks=False):
              stack.append(entry_path)
            elif entry.is_file(follow_symlinks=False):
              file_count += 1
              total_bytes += entry_stat.st_size
            else:
              total_bytes += entry_stat.st_size

          except OSError:
            errors += 1
            needs_sudo = needs_sudo or os.geteuid() != 0

    except OSError:
      errors += 1
      needs_sudo = needs_sudo or os.geteuid() != 0

  return file_count, total_bytes, errors, needs_sudo


# ---------------------------------------------------------------------------
# fd discovery and candidate construction
# ---------------------------------------------------------------------------

def find_fd_binary() -> str:
  """Return fd binary path. On some distributions it is named fdfind."""
  for name in ("fd", "fdfind"):
    binary = shutil.which(name)
    if binary:
      return binary

  print_msg(
    "[red]Error:[/red] could not find 'fd' or 'fdfind' in PATH.\n"
    "Install it on Arch Linux with: sudo pacman -S fd",
  )
  sys.exit(127)


def run_fd(args: argparse.Namespace, search_root: Path, term: str) -> list[Path]:
  """Run fd and return absolute result paths."""
  fd_bin = find_fd_binary()
  command = [
    fd_bin,
    "--color=never",
    "--absolute-path",
    "--fixed-strings",
  ]

  if args.hidden:
    command.append("--hidden")

  if args.no_ignore:
    command.append("--no-ignore")

  if not args.recursive:
    command.extend(["--max-depth", str(args.depth)])

  command.extend([term, str(search_root)])

  if args.verbose:
    print_msg("[dim]fd command:[/dim] " + " ".join(command))

  process = subprocess.run(
    command,
    check=False,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
  )

  if process.returncode not in (0, 1):
    print_msg("[red]fd failed:[/red]\n" + process.stderr.strip())
    sys.exit(process.returncode)

  if args.verbose and process.stderr.strip():
    print_msg("[yellow]fd stderr:[/yellow]\n" + process.stderr.strip())

  return [resolve_path(line) for line in process.stdout.splitlines() if line]


def build_candidates(matches: Iterable[Path], search_root: Path) -> list[Candidate]:
  """Convert fd matches into folder-level deletion candidates."""
  candidates: dict[Path, Candidate] = {}

  for match in matches:
    match = match.resolve(strict=False)

    if is_dir_no_follow(match):
      target = match
      is_folder_match = True
    else:
      target = match.parent
      is_folder_match = False

    candidate = candidates.setdefault(target, Candidate(path=target))
    candidate.raw_matches.append(match)

    if is_folder_match:
      candidate.matched_dirs += 1
    else:
      candidate.matched_files += 1

  analysed: list[Candidate] = []

  for candidate in candidates.values():
    candidate.blocked_reason = deletion_block_reason(
      candidate.path,
      search_root,
    )

    if is_dir_no_follow(candidate.path):
      files, bytes_total, errors, needs_sudo = scan_tree(candidate.path)
      candidate.total_files = files
      candidate.total_bytes = bytes_total
      candidate.scan_errors = errors
      candidate.needs_sudo = needs_sudo
    else:
      candidate.blocked_reason = "candidate is not a directory"

    analysed.append(candidate)

  analysed.sort(key=lambda item: (item.total_bytes, str(item.path)), reverse=True)

  for index, candidate in enumerate(analysed, start=1):
    candidate.index = index

  return analysed


# ---------------------------------------------------------------------------
# Rendering and user interaction
# ---------------------------------------------------------------------------

def candidate_status(candidate: Candidate) -> str:
  """Return a display status for a candidate."""
  if candidate.blocked_reason:
    return f"blocked: {candidate.blocked_reason}"

  if os.geteuid() == 0:
    return "root session; confirmation required"

  if candidate.needs_sudo:
    return "requires sudo"

  return "ok"


def render_candidates(candidates: list[Candidate]) -> None:
  """Render the candidate table."""
  if HAVE_RICH and CONSOLE is not None:
    table = Table(title="Candidate folders")
    table.add_column("#", justify="right")
    table.add_column("Folder", overflow="fold")
    table.add_column("Reason", overflow="fold")
    table.add_column("fd matches", justify="right")
    table.add_column("Files", justify="right")
    table.add_column("Total size", justify="right")
    table.add_column("Status", overflow="fold")

    for candidate in candidates:
      status = candidate_status(candidate)
      status_text = Text(status)

      if candidate.blocked_reason:
        status_text.stylize("red")
      elif candidate.needs_sudo or os.geteuid() == 0:
        status_text.stylize("yellow")
      else:
        status_text.stylize("green")

      table.add_row(
        str(candidate.index),
        str(candidate.path),
        candidate.reason,
        str(candidate.fd_matches),
        str(candidate.total_files),
        human_bytes(candidate.total_bytes),
        status_text,
      )

    CONSOLE.print(table)
    return

  print("Candidate folders")
  print("-" * 80)

  for candidate in candidates:
    print(
      f"{candidate.index:>3}  {candidate.path}\n"
      f"     reason: {candidate.reason}\n"
      f"     fd matches: {candidate.fd_matches}\n"
      f"     files: {candidate.total_files}\n"
      f"     total size: {human_bytes(candidate.total_bytes)}\n"
      f"     status: {candidate_status(candidate)}"
    )


def parse_selection(text: str, candidates: list[Candidate]) -> list[Candidate]:
  """Parse 'all', '1,3,5', or '1-4' into selected candidates."""
  text = text.strip().lower()

  if not text:
    return []

  by_index = {candidate.index: candidate for candidate in candidates}

  if text in {"a", "all"}:
    return list(candidates)

  selected: dict[int, Candidate] = {}

  for chunk in text.split(","):
    chunk = chunk.strip()

    if not chunk:
      continue

    if "-" in chunk:
      left, right = chunk.split("-", maxsplit=1)
      start = int(left)
      stop = int(right)

      if start > stop:
        start, stop = stop, start

      for index in range(start, stop + 1):
        if index in by_index:
          selected[index] = by_index[index]
      continue

    index = int(chunk)

    if index in by_index:
      selected[index] = by_index[index]

  return list(selected.values())


def prompt_selection(candidates: list[Candidate]) -> list[Candidate]:
  """Ask the user which candidates should be deleted."""
  print_msg(
    "Enter candidate numbers to delete, e.g. [cyan]1,3-5[/cyan], "
    "or [cyan]all[/cyan]. Empty input cancels.",
  )

  while True:
    try:
      raw = input("Delete selection: ")
      return parse_selection(raw, candidates)
    except ValueError:
      print_msg("[red]Invalid selection.[/red] Use all, 1,3, or 1-4.")


def prompt_yes_no(question: str) -> bool:
  """Prompt for a simple yes/no answer."""
  answer = input(f"{question} [y/N] ").strip().lower()
  return answer in {"y", "yes"}


def remove_nested_duplicates(candidates: list[Candidate]) -> list[Candidate]:
  """Avoid trying to delete a folder after deleting its ancestor."""
  ordered = sorted(candidates, key=lambda item: len(item.path.parts))
  kept: list[Candidate] = []

  for candidate in ordered:
    if any(path_is_relative_to(candidate.path, kept_item.path) for kept_item in kept):
      continue
    kept.append(candidate)

  return kept


# ---------------------------------------------------------------------------
# Deletion
# ---------------------------------------------------------------------------

def delete_candidates(candidates: list[Candidate], args: argparse.Namespace) -> int:
  """Delete selected candidates recursively, respecting safety rules."""
  unblocked = [item for item in candidates if not item.blocked_reason]

  if not unblocked:
    print_msg("[yellow]No deletable folders were found.[/yellow]")
    return 0

  ordinary_run = os.geteuid() != 0 and not any(item.needs_sudo for item in unblocked)

  if args.noconfirm and ordinary_run:
    selected = unblocked
  else:
    selected = prompt_selection(unblocked)

  if not selected:
    print_msg("[yellow]No deletion performed.[/yellow]")
    return 0

  skipped_sudo = [item for item in selected if item.needs_sudo and os.geteuid() != 0]
  selected = [item for item in selected if not item.needs_sudo or os.geteuid() == 0]

  if skipped_sudo:
    print_msg(
      "[yellow]Some selected folders require sudo and were skipped.[/yellow] "
      "Run this script with sudo if you really intend to remove them.",
    )

    for item in skipped_sudo:
      print_msg(f"  - {item.path}")

  selected = remove_nested_duplicates(selected)

  if not selected:
    print_msg("[yellow]No deletable non-sudo folders remain.[/yellow]")
    return 0

  total_size = sum(item.total_bytes for item in selected)
  print_msg(
    f"[bold]Recursive deletion target:[/bold] {len(selected)} folder(s), "
    f"approximately {human_bytes(total_size)}.",
  )

  privileged_prompt = os.geteuid() == 0 or any(item.needs_sudo for item in selected)

  if privileged_prompt:
    answer = input("Type DELETE to confirm privileged recursive deletion: ")

    if answer != "DELETE":
      print_msg("[yellow]Deletion cancelled.[/yellow]")
      return 0
  elif not args.noconfirm:
    if not prompt_yes_no("Recursively delete the selected folder(s)?"):
      print_msg("[yellow]Deletion cancelled.[/yellow]")
      return 0

  deleted = 0

  for candidate in selected:
    try:
      if args.verbose:
        print_msg(f"[dim]Deleting:[/dim] {candidate.path}")

      shutil.rmtree(candidate.path)
      deleted += 1
      print_msg(f"[green]Deleted:[/green] {candidate.path}")
    except OSError as exc:
      print_msg(f"[red]Failed:[/red] {candidate.path}: {exc}")

  print_msg(f"[bold]Deleted {deleted} folder(s).[/bold]")
  return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args(argv: list[str]) -> argparse.Namespace:
  """Parse command-line arguments."""
  parser = argparse.ArgumentParser(
    prog="fd-folder-clean",
    formatter_class=argparse.RawDescriptionHelpFormatter,
    description=(
      "Find folders associated with fd matches, show their recursive size, "
      "and optionally delete selected folders recursively."
    ),
    epilog="""
Examples:
  fd-folder-clean cache
  fd-folder-clean -p ~/.cache cache -r
  fd-folder-clean -p ~/Downloads -s AppImage -d 3
  fd-folder-clean -p ~/.cache -r cache --delete
  fd-folder-clean -p ~/.cache -r cache --delete --noconfirm
  sudo fd-folder-clean -p /opt -r old-package --delete

Notes:
  - Without --delete, this script only inspects and prints candidate folders.
  - Directory matches become deletion candidates directly.
  - File matches make their parent folder a deletion candidate.
  - Deletion of /, root-level folders, $HOME, and the search root is refused.
""".strip(),
  )

  parser.add_argument(
    "term",
    nargs="?",
    help="search term; this is the only positional argument accepted",
  )
  parser.add_argument(
    "-p",
    "--path",
    default=".",
    help="path to search; default: current directory",
  )
  parser.add_argument(
    "-s",
    "--search",
    "--search-term",
    dest="search_term",
    help="search term; alternative to the positional term",
  )

  depth_group = parser.add_mutually_exclusive_group()
  depth_group.add_argument(
    "-r",
    "--recursive",
    action="store_true",
    help="search recursively without a maximum depth",
  )
  depth_group.add_argument(
    "-d",
    "--depth",
    type=int,
    default=1,
    help="maximum fd search depth; default: 1",
  )

  parser.add_argument(
    "--delete",
    action="store_true",
    help="delete selected candidate folders recursively",
  )
  parser.add_argument(
    "--noconfirm",
    action="store_true",
    help="do not prompt for ordinary non-sudo deletion",
  )
  parser.add_argument(
    "--hidden",
    action="store_true",
    help="include hidden files and directories in fd search",
  )
  parser.add_argument(
    "--no-ignore",
    action="store_true",
    help="make fd ignore .gitignore, .ignore, and similar ignore files",
  )
  parser.add_argument(
    "-v",
    "--verbose",
    action="store_true",
    help="print fd command and deletion details",
  )

  args = parser.parse_args(argv)

  if args.term and args.search_term:
    parser.error("give the search term either positionally or with -s, not both")

  args.search_term = args.search_term or args.term

  if not args.search_term:
    parser.error("a search term is required")

  if args.depth is not None and args.depth < 1:
    parser.error("--depth must be >= 1")

  return args


def main(argv: list[str]) -> int:
  """Entry point."""
  args = parse_args(argv)
  search_root = resolve_path(args.path)

  if not search_root.exists():
    print_msg(f"[red]Error:[/red] path does not exist: {search_root}")
    return 2

  if not search_root.is_dir():
    print_msg(f"[red]Error:[/red] path is not a directory: {search_root}")
    return 2

  matches = run_fd(args, search_root, args.search_term)

  print_msg(
    f"[bold]fd matches:[/bold] {len(matches)} item(s) under "
    f"[cyan]{search_root}[/cyan]",
  )

  if not matches:
    return 0

  candidates = build_candidates(matches, search_root)
  render_candidates(candidates)

  blocked = [item for item in candidates if item.blocked_reason]
  sudo_needed = [item for item in candidates if item.needs_sudo]

  if blocked:
    print_msg(
      f"[yellow]{len(blocked)} candidate(s) are blocked by hard safety "
      "rules and cannot be deleted by this script.[/yellow]",
    )

  if sudo_needed and os.geteuid() != 0:
    print_msg(
      f"[yellow]{len(sudo_needed)} candidate(s) appear to require sudo. "
      "They will be skipped unless you rerun the script with sudo.[/yellow]",
    )

  if not args.delete:
    print_msg("[dim]Inspection only. Add --delete to remove folders.[/dim]")
    return 0

  return delete_candidates(candidates, args)


if __name__ == "__main__":
  raise SystemExit(main(sys.argv[1:]))
