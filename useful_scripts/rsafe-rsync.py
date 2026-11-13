#!/usr/bin/env python3
"""
rsafe-sync

Safe rsync wrapper with explicit conflict handling.

Default behaviour:
  - copy SOURCE... into DESTINATION
  - never overwrite existing files
  - abort if conflicts are detected
  - show a progress/status display
  - use rsync for the actual transfer

Examples:
  rsafe-sync file1.png file2.jpg /shared/pictures

  rsafe-sync --dry-run *.png /shared/pictures

  rsafe-sync --auto-rename *.png /shared/pictures

  rsafe-sync --skip-conflicts *.png /shared/pictures

  rsafe-sync --preserve-structure --base-dir "$HOME" \
    "$HOME/to-onedrive/a.jpg" \
    "$HOME/repos/UserScripts/b.png" \
    /shared/backup

  rsafe-sync --delete-source-files --auto-rename \
    "$HOME/to-onedrive" \
    /shared/backup

  rsafe-sync --interactive --search-dir ~/Pictures -e png -e jpg \
    --dry-run /shared/pictures

Optional selection requires fd, fzf, and file_picker.py alongside this script.
bat enables previews. Tab or Shift-click marks files; Enter accepts them.
"""

from __future__ import annotations

import argparse
import os
import math
import re
import selectors
import shlex
import time
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable


try:
  from rich.console import Console
  from rich.progress import (
    BarColumn,
    Progress,
    SpinnerColumn,
    TextColumn,
    TimeElapsedColumn,
  )
  from rich.table import Table

  HAVE_RICH = True
except ImportError:
  HAVE_RICH = False
  Console = None


# -----------------------------------------------------------------------------
# Data structures
# -----------------------------------------------------------------------------

@dataclass(frozen=True)
class TransferItem:
  source: Path
  target: Path
  size: int
  note: str = ""


@dataclass(frozen=True)
class SkippedItem:
  source: Path
  target: Path
  reason: str


# -----------------------------------------------------------------------------
# General helpers
# -----------------------------------------------------------------------------

def die(message: str, exit_code: int = 1) -> None:
  print(f"Error: {message}", file=sys.stderr)
  raise SystemExit(exit_code)


def as_abs_path(path: str | Path) -> Path:
  return Path(path).expanduser().absolute()


def require_rsync() -> None:
  if shutil.which("rsync") is None:
    die("rsync was not found in PATH. Install it first, e.g. pacman -S rsync.")


def file_size(path: Path) -> int:
  try:
    return path.lstat().st_size
  except OSError:
    return 0


def iter_source_files(source: Path) -> Iterable[Path]:
  if not source.exists() and not source.is_symlink():
    die(f"source does not exist: {source}")

  if source.is_file() or source.is_symlink():
    yield source
    return

  if source.is_dir():
    for root, dirs, files in os.walk(source):
      dirs.sort()
      files.sort()

      for filename in files:
        yield Path(root) / filename

    return

  die(f"unsupported source type: {source}")


def common_base_for_sources(sources: list[Path]) -> Path:
  bases: list[str] = []

  for source in sources:
    if source.is_dir():
      bases.append(str(source.parent))
    else:
      bases.append(str(source.parent))

  return Path(os.path.commonpath(bases))


def relative_to_base(path: Path, base: Path) -> Path:
  try:
    return path.relative_to(base)
  except ValueError:
    die(f"path is not inside base-dir:\n  path: {path}\n  base: {base}")


def unique_target(path: Path, reserved: set[Path]) -> Path:
  if not path.exists() and path not in reserved:
    return path

  parent = path.parent
  stem = path.stem
  suffix = path.suffix

  counter = 1
  while True:
    candidate = parent / f"{stem}_[{counter}]{suffix}"
    if not candidate.exists() and candidate not in reserved:
      return candidate
    counter += 1


# -----------------------------------------------------------------------------
# Planning
# -----------------------------------------------------------------------------

def planned_target_for_file(
  *,
  file_path: Path,
  top_source: Path,
  destination: Path,
  preserve_structure: bool,
  base_dir: Path,
) -> Path:
  if preserve_structure:
    return destination / relative_to_base(file_path, base_dir)

  if top_source.is_dir():
    rel = file_path.relative_to(top_source)
    return destination / top_source.name / rel

  return destination / file_path.name


def build_plan(
  *,
  sources: list[Path],
  destination: Path,
  preserve_structure: bool,
  base_dir: Path,
  auto_rename: bool,
  skip_conflicts: bool,
  overwrite: bool,
  selected_files: list[Path] | None = None,
) -> tuple[list[TransferItem], list[SkippedItem], list[str]]:
  transfers: list[TransferItem] = []
  skipped: list[SkippedItem] = []
  conflicts: list[str] = []
  reserved_targets: set[Path] = set()
  planned_sources: set[Path] = set()

  for top_source in sources:
    if selected_files is None:
      files = iter_source_files(top_source)
    else:
      # Keep the original directory layout, without walking unselected files.
      files = (
        path for path in selected_files
        if path == top_source or (
          top_source.is_dir() and path.is_relative_to(top_source)
        )
      )
    for file_path in files:
      if selected_files is not None:
        if file_path in planned_sources:
          continue
        planned_sources.add(file_path)
      target = planned_target_for_file(
        file_path=file_path,
        top_source=top_source,
        destination=destination,
        preserve_structure=preserve_structure,
        base_dir=base_dir,
      )

      target_exists = target.exists()
      target_reserved = target in reserved_targets

      if target_exists or target_reserved:
        if auto_rename:
          original = target
          target = unique_target(target, reserved_targets)
          note = f"renamed from {original.name}"
        elif skip_conflicts:
          skipped.append(
            SkippedItem(
              source=file_path,
              target=target,
              reason="target already exists or is planned twice",
            )
          )
          continue
        elif overwrite and not target_reserved:
          note = "overwrite"
        else:
          conflicts.append(f"{file_path} -> {target}")
          continue
      else:
        note = ""

      reserved_targets.add(target)
      transfers.append(
        TransferItem(
          source=file_path,
          target=target,
          size=file_size(file_path),
          note=note,
        )
      )

  return transfers, skipped, conflicts


# -----------------------------------------------------------------------------
# Display helpers
# -----------------------------------------------------------------------------

def print_plan_plain(
  *,
  transfers: list[TransferItem],
  skipped: list[SkippedItem],
  dry_run: bool,
) -> None:
  title = "Dry-run transfer plan" if dry_run else "Transfer plan"
  print(f"\n{title}")
  print("-" * len(title))

  for item in transfers:
    note = f" [{item.note}]" if item.note else ""
    print(f"COPY {item.source} -> {item.target}{note}")

  for item in skipped:
    print(f"SKIP {item.source} -> {item.target} [{item.reason}]")

  print()
  print(f"Files to copy: {len(transfers)}")
  print(f"Files skipped: {len(skipped)}")
  print(f"Bytes planned: {sum(item.size for item in transfers)}")


def print_plan_rich(
  *,
  transfers: list[TransferItem],
  skipped: list[SkippedItem],
  dry_run: bool,
) -> None:
  console = Console()
  title = "Dry-run transfer plan" if dry_run else "Transfer plan"

  table = Table(title=title)
  table.add_column("Action", no_wrap=True)
  table.add_column("Source")
  table.add_column("Target")
  table.add_column("Note")

  max_rows = 80
  rows = 0

  for item in transfers[:max_rows]:
    table.add_row("COPY", str(item.source), str(item.target), item.note)
    rows += 1

  for item in skipped[:max(0, max_rows - rows)]:
    table.add_row("SKIP", str(item.source), str(item.target), item.reason)

  omitted = len(transfers) + len(skipped) - max_rows
  if omitted > 0:
    table.add_row("…", f"{omitted} additional rows omitted", "", "")

  console.print(table)
  console.print(f"Files to copy: {len(transfers)}")
  console.print(f"Files skipped: {len(skipped)}")
  console.print(f"Bytes planned: {sum(item.size for item in transfers)}")


def print_plan(
  *,
  transfers: list[TransferItem],
  skipped: list[SkippedItem],
  dry_run: bool,
) -> None:
  if HAVE_RICH:
    print_plan_rich(transfers=transfers, skipped=skipped, dry_run=dry_run)
  else:
    print_plan_plain(transfers=transfers, skipped=skipped, dry_run=dry_run)


# -----------------------------------------------------------------------------
# Rsync execution
# -----------------------------------------------------------------------------

def rsync_one_file(
  item: TransferItem, *, quiet: bool, ionice: bool = False,
  priority: int = 4, verbose: bool = False,
  on_progress: Callable[[int], None] | None = None,
  log: Callable[[str], None] = print,
) -> None:
  item.target.parent.mkdir(parents=True, exist_ok=True)
  command = [
    "rsync", "-a", "--partial", "--protect-args",
    "--info=progress2", "--outbuf=L",
  ]
  if verbose:
    command.append("--verbose")
  command.extend(["--", str(item.source), str(item.target)])
  if ionice:
    command = ["ionice", "-c", "2", "-n", str(priority), *command]
  if verbose:
    log(f"Running: {shlex.join(command)}")

  transferred = 0
  pending = b""
  errors: list[str] = []
  # Read binary chunks: rsync's live records end with CR rather than newline.
  with subprocess.Popen(
    command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    env={**os.environ, "LC_ALL": "C"},
  ) as process:
    try:
      with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        while selector.get_map():
          for key, _ in selector.select(timeout=0.25):
            chunk = os.read(key.fileobj.fileno(), 65536)
            if key.data == "stderr":
              if chunk:
                errors.append(chunk.decode(errors="replace"))
            else:
              pending += chunk
              records = re.split(rb"[\r\n]", pending)
              pending = records.pop()
              if not chunk and pending:
                records.append(pending)
                pending = b""
              for record in records:
                line = record.decode(errors="replace")
                match = re.match(r"^\s*([\d,]+)\s+\d+%", line)
                if match:
                  transferred = max(transferred, min(item.size, int(match[1].replace(",", ""))))
                elif verbose and line.strip():
                  log(line)
            if not chunk:
              selector.unregister(key.fileobj)
          if on_progress:
            on_progress(transferred)
      returncode = process.wait()
    except BaseException:
      process.terminate()
      process.wait()
      raise
  if errors:
    sys.stderr.write("".join(errors))
  if returncode != 0:
    die(f"rsync failed for: {item.source}", returncode)
  if on_progress:
    on_progress(item.size)


@dataclass
class SpeedEstimate:
  """Time-based exponential smoothing, including idle intervals."""
  updated: float
  completed: int = 0
  speed: float = 0.0

  def update(self, completed: int, now: float) -> None:
    elapsed = now - self.updated
    if elapsed < 0.2:
      return
    sample = max(0, completed - self.completed) / elapsed
    weight = 1 - math.exp(-elapsed / 5.0)
    self.speed = sample if self.speed == 0 else self.speed + weight * (sample - self.speed)
    self.updated, self.completed = now, completed

  def status(self, total: int, completed: int) -> tuple[str, str]:
    remaining = max(0, total - completed)
    eta = "0s" if remaining == 0 else (
      f"{math.ceil(remaining / self.speed)}s" if self.speed > 0 else "—"
    )
    return f"{self.speed / (1024 * 1024):.2f} MiB/s", eta


def delete_source_file(path: Path) -> None:
  try:
    path.unlink()
  except FileNotFoundError:
    return
  except OSError as error:
    die(f"failed to delete source file {path}: {error}")


def prune_empty_dirs(sources: list[Path]) -> None:
  for source in sources:
    if not source.is_dir():
      continue

    for root, dirs, files in os.walk(source, topdown=False):
      root_path = Path(root)

      try:
        root_path.rmdir()
      except OSError:
        pass


def execute_transfers(
  *,
  transfers: list[TransferItem],
  sources: list[Path],
  delete_source_files: bool,
  prune_dirs: bool,
  ionice: bool = False,
  priority: int = 4,
  verbose: bool = False,
) -> None:
  total_bytes = sum(item.size for item in transfers)

  estimate = SpeedEstimate(time.monotonic())
  copied = 0

  def update_status(current: int) -> tuple[int, str, str]:
    completed = copied + current
    estimate.update(completed, time.monotonic())
    speed, eta = estimate.status(total_bytes, completed)
    return completed, speed, eta

  if HAVE_RICH:
    console = Console()
    with Progress(
      SpinnerColumn(),
      TextColumn("[progress.description]{task.description}"),
      BarColumn(),
      TextColumn("{task.completed}/{task.total} bytes"),
      TextColumn("{task.fields[speed]}"),
      TextColumn("ETA {task.fields[eta]}"),
      TimeElapsedColumn(),
      console=console, refresh_per_second=4,
    ) as progress:
      task = progress.add_task("copying", total=total_bytes, speed="0.00 MiB/s", eta="—")

      def report(current: int) -> None:
        completed, speed, eta = update_status(current)
        progress.update(task, completed=completed, speed=speed, eta=eta)

      for item in transfers:
        progress.update(task, description=f"copying {item.source.name}")
        rsync_one_file(item, quiet=True, ionice=ionice, priority=priority,
                       verbose=verbose, on_progress=report,
                       log=lambda line: console.print(line, markup=False))
        copied += item.size
        if delete_source_files:
          delete_source_file(item.source)
      progress.update(task, description="done", eta="0s")
  else:
    last_display = 0.0

    def report(current: int) -> None:
      nonlocal last_display
      completed, speed, eta = update_status(current)
      now = time.monotonic()
      if now - last_display >= 0.25 or completed == total_bytes:
        print(f"\rCopied {completed}/{total_bytes} bytes | {speed} | ETA {eta}    ",
              end="", flush=True)
        last_display = now

    for index, item in enumerate(transfers, start=1):
      print(f"[{index}/{len(transfers)}] {item.source} -> {item.target}")
      rsync_one_file(item, quiet=True, ionice=ionice, priority=priority,
                     verbose=verbose, on_progress=report,
                     log=lambda line: print(f"\n{line}"))
      copied += item.size
      print()
      if delete_source_files:
        delete_source_file(item.source)

  if delete_source_files and prune_dirs:
    prune_empty_dirs(sources)


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

def add_picker_options(parser: argparse.ArgumentParser) -> None:
  """Describe the optional picker without loading its companion module."""
  group = parser.add_argument_group("optional file picker")
  group.add_argument(
    "-i", "--interactive", action="store_true",
    help="select source files using fd/fzf; supply DESTINATION explicitly",
  )
  group.add_argument(
    "--search-dir", metavar="DIR",
    help="search directory (default: current directory); requires --interactive",
  )
  group.add_argument(
    "-e", "--extension", action="append", default=[], metavar="EXT",
    help="filter extensions, e.g. -e png -e jpg; requires --interactive",
  )
  group.add_argument(
    "--hidden", action="store_true",
    help="include hidden files in discovery; requires --interactive",
  )
  group.add_argument(
    "--no-ignore", action="store_true",
    help="include files ignored by fd; requires --interactive",
  )
  group.add_argument(
    "--no-preview", action="store_true",
    help="disable the optional bat preview; requires --interactive",
  )


def parse_args() -> argparse.Namespace:
  parser = argparse.ArgumentParser(
    description="Safe rsync wrapper with conflict handling.",
    formatter_class=argparse.RawDescriptionHelpFormatter,
    epilog="""
Conflict modes:
  default             abort if any target path already exists
  --auto-rename       copy using file_[1].ext, file_[2].ext, ...
  --skip-conflicts    ignore conflicting files
  --overwrite         explicitly allow overwriting existing target files

Path modes:
  default             files go directly into DESTINATION;
                      directories are copied as DESTINATION/source-name/...

  --preserve-structure
                      preserve paths relative to --base-dir

Interactive selection:
  Requires fd/fzf on PATH; bat previews are optional (Ctrl-P toggles them).
  Tab or Shift-click marks files; Ctrl-A marks all; Ctrl-D clears marks.
  Enter accepts the selection; Esc cancels before creating the destination.
  SOURCE directories keep their normal directory layout for selected files.
  Without SOURCE, search --search-dir (default: .) and copy files directly.
  With --preserve-structure, --search-dir is the default base in that mode.
  fd skips hidden/ignored files unless --hidden / --no-ignore is supplied.

Examples:
  rsafe-sync a.png b.jpg /shared/pictures

  rsafe-sync --dry-run --auto-rename *.png /shared/pictures

  rsafe-sync --interactive --search-dir ~/Pictures -e png -e jpg \\
    --dry-run /shared/pictures

  rsafe-sync --skip-conflicts "$HOME/to-onedrive" /shared/backup

  rsafe-sync --preserve-structure --base-dir "$HOME" \\
    "$HOME/to-onedrive/a.jpg" \\
    "$HOME/repos/UserScripts/b.png" \\
    /shared/backup

  rsafe-sync --delete-source-files --prune-empty-dirs \\
    --auto-rename "$HOME/to-onedrive" /shared/backup
""",
  )

  parser.add_argument(
    "paths",
    nargs="+",
    help="SOURCE... DESTINATION; SOURCE is optional with --interactive",
  )

  parser.add_argument(
    "--dry-run",
    action="store_true",
    help="show the planned copy operations without copying anything",
  )

  parser.add_argument(
    "--auto-rename",
    action="store_true",
    help="rename conflicting targets as file_[1].ext, file_[2].ext, ...",
  )

  parser.add_argument(
    "--skip-conflicts",
    action="store_true",
    help="skip files whose target already exists",
  )

  parser.add_argument(
    "--overwrite",
    action="store_true",
    help="explicitly allow overwriting existing target files",
  )

  parser.add_argument(
    "--delete-source-files",
    action="store_true",
    help="delete each source file only after successful rsync copy",
  )

  parser.add_argument(
    "--prune-empty-dirs",
    action="store_true",
    help="after --delete-source-files, remove empty source directories",
  )

  parser.add_argument(
    "--preserve-structure",
    action="store_true",
    help="preserve source paths relative to --base-dir",
  )

  parser.add_argument(
    "--base-dir",
    default=None,
    help="base directory for --preserve-structure",
  )

  parser.add_argument("--ionice", action="store_true",
                      help="use best-effort I/O scheduling (default priority: 4)")
  parser.add_argument("--priority", type=int, choices=range(8), default=None,
                      help="I/O priority: 0 highest, 7 lowest; implies --ionice")
  parser.add_argument("--verbose", "-V", action="store_true",
                      help="show executed commands and detailed rsync output")
  add_picker_options(parser)
  return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
  conflict_modes = [
    args.auto_rename,
    args.skip_conflicts,
    args.overwrite,
  ]

  if sum(bool(mode) for mode in conflict_modes) > 1:
    die("choose only one of --auto-rename, --skip-conflicts, or --overwrite")

  if len(args.paths) < 2 and not args.interactive:
    die("provide at least one source and one destination")

  picker_options = (
    args.search_dir, args.extension, args.hidden,
    args.no_ignore, args.no_preview,
  )
  if any(picker_options) and not args.interactive:
    die("file picker options require --interactive", 2)
  if args.search_dir is not None and len(args.paths) > 1:
    die("choose either SOURCE paths or --search-dir for picker candidates", 2)

  if args.prune_empty_dirs and not args.delete_source_files:
    die("--prune-empty-dirs requires --delete-source-files")


def main() -> int:
  args = parse_args()
  validate_args(args)
  require_rsync()
  use_ionice = args.ionice or args.priority is not None
  if use_ionice and shutil.which("ionice") is None:
    die("ionice was not found in PATH; install util-linux to use I/O priorities")

  raw_sources = args.paths[:-1]
  raw_destination = args.paths[-1]

  sources = [as_abs_path(path) for path in raw_sources]
  destination = as_abs_path(raw_destination)
  selected_files = None
  search_root = as_abs_path(args.search_dir or ".")

  if args.interactive:
    try:
      from file_picker import select_files
    except ModuleNotFoundError as error:
      if error.name != "file_picker":
        raise
      die("--interactive requires file_picker.py alongside this script", 2)
    sources = [Path(os.path.abspath(path)) for path in sources]
    search_root = Path(os.path.abspath(search_root))
    if not raw_sources and not search_root.is_dir():
      die(f"search directory is not a directory: {search_root}", 2)
    selected_files = select_files(
      args, sources=sources or [search_root], multiple=True,
    )
    if not sources:
      sources = selected_files

  if destination.exists() and not destination.is_dir():
    die("destination must be a directory")

  if args.base_dir is not None:
    base_dir = as_abs_path(args.base_dir)
    if args.interactive:
      base_dir = Path(os.path.abspath(base_dir))
  elif args.interactive and not raw_sources:
    base_dir = search_root
  else:
    base_dir = common_base_for_sources(sources)

  transfers, skipped, conflicts = build_plan(
    sources=sources,
    destination=destination,
    preserve_structure=args.preserve_structure,
    base_dir=base_dir,
    auto_rename=args.auto_rename,
    skip_conflicts=args.skip_conflicts,
    overwrite=args.overwrite,
    selected_files=selected_files,
  )

  if conflicts:
    print("Conflicts detected. Nothing was copied.", file=sys.stderr)
    print(file=sys.stderr)
    for conflict in conflicts[:80]:
      print(f"  {conflict}", file=sys.stderr)

    if len(conflicts) > 80:
      print(f"  ... {len(conflicts) - 80} more conflicts", file=sys.stderr)

    print(file=sys.stderr)
    print("Use one of:", file=sys.stderr)
    print("  --auto-rename", file=sys.stderr)
    print("  --skip-conflicts", file=sys.stderr)
    print("  --overwrite", file=sys.stderr)
    return 1

  print_plan(transfers=transfers, skipped=skipped, dry_run=args.dry_run)

  if args.dry_run:
    return 0

  if not transfers:
    print("No files to copy.")
    return 0

  destination.mkdir(parents=True, exist_ok=True)
  prune_sources = sources
  if args.interactive and not raw_sources:
    prune_sources = [search_root]
  execute_transfers(
    transfers=transfers,
    sources=prune_sources,
    delete_source_files=args.delete_source_files,
    prune_dirs=args.prune_empty_dirs,
    ionice=use_ionice,
    priority=args.priority if args.priority is not None else 4,
    verbose=args.verbose,
  )

  print("Done.")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
