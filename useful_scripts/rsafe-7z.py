#!/usr/bin/env python3
"""Rich 7z wrapper with optional fd/fzf selection and safe conflict modes.

Examples:
  rsafe-7z a Documents backup.7z --encrypt-headers --ask-password
  rsafe-7z --archive -i --pick-types --search-dir ~/Pictures photos.7z
  rsafe-7z e backup.7z restored --ask-password
  rsafe-7z --extract -i --search-dir ~/Downloads -e 7z restored

Keep file_picker.py alongside this script for interactive selection.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import selectors
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from collections import Counter, deque
from contextlib import nullcontext
from pathlib import Path

try:
  from rich.console import Console
  from rich.progress import (
    BarColumn,
    Progress,
    SpinnerColumn,
    TaskProgressColumn,
    TextColumn,
    TimeElapsedColumn,
  )
  from rich.table import Table
  from rich.text import Text
except ImportError:
  Console = None


# -- CLI and validation -------------------------------------------------------

def fail(message: str, code: int = 2) -> None:
  print(f"Error: {message}", file=sys.stderr)
  raise SystemExit(code)


def absolute_path(raw: str | Path) -> Path:
  return Path(os.path.abspath(Path(raw).expanduser()))


def build_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(
    description="7z archives with Rich progress and fd/fzf selection.",
    formatter_class=argparse.RawDescriptionHelpFormatter,
    epilog="""
Actions:
  a / --archive       create a new .7z archive: SOURCE... ARCHIVE
  e / --extract       extract with directories: ARCHIVE... DESTINATION
                      use --flatten for native 7z e behavior

Interactive selection:
  -i opens the shared file picker. --pick-types opens a type picker first.
  With no SOURCE/ARCHIVE, search --search-dir (default: current directory).
  -e EXT filters input files, including archives on disk for extraction.
  Tab marks files/types; Ctrl-A selects all; Enter accepts; Esc cancels.
  Requires fd, fzf and file_picker.py; bat previews are optional.

Paths and conflicts:
  Archive paths are relative to the common parent of SOURCE paths, or the
  search directory when SOURCE is omitted. --base-dir overrides that base.
  An existing archive causes an error by default. --overwrite replaces it
  with a NEW archive, rather than updating or retaining old members.
  Extraction skips existing files by default. --auto-rename keeps both;
  --overwrite replaces existing files. Multiple input archives extract into
  DESTINATION/archive-name/ directories, one per archive.
  --delete-source-files removes archived files only after testing and publishing
  the new archive. --prune-empty-dirs also removes empty source directories.
  Dry runs display the plan without prompting for passwords or writing files.

Examples:
  rsafe-7z a Documents backup.7z --ask-password --encrypt-headers
  rsafe-7z --archive --pick-types --search-dir ~/Pictures photos.7z
  rsafe-7z a -i -e png -e jpg --search-dir ~/Pictures --dry-run photos.7z
  rsafe-7z a --pick-types --search-dir ~/Pictures photos.7z \\
    --delete-source-files --prune-empty-dirs
  rsafe-7z e backup.7z restored --password 'your password'
  rsafe-7z --extract -i --search-dir ~/Downloads -e 7z restored
  rsafe-7z a Documents backup.7z -p'password' -mhe=on
""",
  )
  action = parser.add_mutually_exclusive_group(required=True)
  action.add_argument("-a", "--archive", dest="action", action="store_const",
                      const="archive", help="create an archive; alias: a")
  action.add_argument("--extract", dest="action", action="store_const",
                      const="extract", help="extract archives; alias: e")
  parser.add_argument("paths", nargs="+", metavar="PATH",
                      help="SOURCE... ARCHIVE or ARCHIVE... DESTINATION")
  password = parser.add_mutually_exclusive_group()
  password.add_argument("-p", "--password", metavar="PASSWORD",
                        help="encryption/decryption password; -pPASSWORD works")
  password.add_argument("--ask-password", action="store_true",
                        help="prompt privately for a password")
  headers = parser.add_mutually_exclusive_group()
  headers.add_argument("--encrypt-headers", dest="headers", action="store_const",
                       const="on", help="encrypt filenames; implies a prompt")
  headers.add_argument("-mhe", dest="headers", choices=("on", "off"),
                       help="native header option: -mhe=on")
  parser.set_defaults(headers="off")
  parser.add_argument("--dry-run", action="store_true",
                      help="show the plan without creating or extracting files")
  parser.add_argument("--delete-source-files", action="store_true",
                      help="delete archived source files after verification "
                           "and publication (archiving only)")
  parser.add_argument("--prune-empty-dirs", action="store_true",
                      help="after --delete-source-files, remove empty source "
                           "directories (archiving only)")
  conflicts = parser.add_mutually_exclusive_group()
  conflicts.add_argument("--auto-rename", action="store_true",
                         help="give conflicting output files a new name")
  conflicts.add_argument("--skip-conflicts", action="store_true",
                         help="skip existing archives/files")
  conflicts.add_argument("--overwrite", action="store_true",
                         help="explicitly replace existing archives/files")
  parser.add_argument("--flatten", action="store_true",
                      help="extract without directories (native 7z e)")
  parser.add_argument("--base-dir", metavar="DIR",
                      help="store archive paths relative to DIR")
  parser.add_argument("--level", type=int, choices=range(10), default=5,
                      help="compression level 0..9 (default: 5)")
  parser.add_argument("-V", "--verbose", action="store_true",
                      help="show redacted commands and detailed 7z output")
  picker = parser.add_argument_group("optional file picker")
  picker.add_argument("-i", "--interactive", action="store_true",
                      help="select input files with fd/fzf")
  picker.add_argument("--pick-types", action="store_true",
                      help="choose types in fzf first; implies --interactive")
  picker.add_argument("--search-dir", metavar="DIR",
                      help="picker search root (default: current directory)")
  picker.add_argument("-e", "--extension", action="append", default=[],
                      metavar="EXT", help="input extension; repeat for more")
  picker.add_argument("--hidden", action="store_true",
                      help="include hidden files in interactive discovery")
  picker.add_argument("--no-ignore", action="store_true",
                      help="include ignored files in interactive discovery")
  picker.add_argument("--no-preview", action="store_true",
                      help="disable the optional bat preview")
  return parser


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
  argv = list(sys.argv[1:] if argv is None else argv)
  if argv and argv[0] in ("a", "e"):
    argv[0] = "--archive" if argv[0] == "a" else "--extract"
  parser = build_parser()
  # Accept options before or after paths, as the other wrappers do.
  args = parser.parse_intermixed_args(argv)
  if args.pick_types:
    args.interactive = True
  if len(args.paths) < 2 and not args.interactive:
    parser.error("provide at least one input and one output path")
  if any((args.search_dir, args.extension, args.hidden, args.no_ignore,
          args.no_preview)) and not args.interactive:
    parser.error("file picker options require --interactive or --pick-types")
  if args.search_dir is not None and len(args.paths) > 1:
    parser.error("choose either input paths or --search-dir")
  if args.action == "extract" and (args.headers == "on" or args.base_dir):
    parser.error("header encryption and --base-dir apply only to archiving")
  if args.action == "archive" and args.flatten:
    parser.error("--flatten applies only to extraction")
  if args.action == "extract" and (args.delete_source_files
                                   or args.prune_empty_dirs):
    parser.error("--delete-source-files and --prune-empty-dirs apply only "
                 "to archiving")
  if args.prune_empty_dirs and not args.delete_source_files:
    parser.error("--prune-empty-dirs requires --delete-source-files")
  if args.password is not None and (not args.password or "\0" in args.password):
    parser.error("the password must be nonempty and cannot contain NUL")
  return args


# -- Optional type and file selection -----------------------------------------

def file_type(path: Path) -> str:
  name = path.name.casefold()
  for extension in ("tar.gz", "tar.bz2", "tar.xz", "tar.zst", "tar.lz"):
    if name.endswith(f".{extension}"):
      return extension
  return path.suffix.lstrip(".").casefold()


def pick_type_candidates(args: argparse.Namespace, sources: list[Path],
                         picker) -> list[Path]:
  fd = shutil.which("fd") or shutil.which("fdfind")
  fzf = shutil.which("fzf")
  if not fd or not fzf:
    fail("--pick-types requires fd and fzf on PATH; "
         "on Arch: sudo pacman -S --needed fd fzf")
  if not sys.stdin.isatty():
    fail("--pick-types requires a terminal on standard input")
  candidates = picker.discover_files(fd, sources, args)
  if not candidates:
    fail("no matching files found; no files were changed", 1)
  counts = Counter(file_type(path) for path in candidates)
  identities = {str(i).encode(): extension
                for i, extension in enumerate(sorted(counts))}
  records = []
  for identity, extension in identities.items():
    label = json.dumps(extension or "(no extension)", ensure_ascii=True)
    records.append(identity + b"\t" + f"{label} ({counts[extension]})".encode())
  command = [
    fzf, "--read0", "--print0", "--multi", "--layout=reverse", "--border",
    "--delimiter=\t", "--with-nth=2..", "--prompt=File types> ",
    "--bind=enter:accept,esc:abort,ctrl-c:abort",
    (
      "--bind=tab:toggle+down,shift-tab:toggle+up,shift-left-click:toggle,"
      "ctrl-a:select-all,ctrl-d:deselect-all"
    ),
    "--header=Tab: mark types | Ctrl-A: all | Enter: files | Esc: cancel",
  ]
  env = os.environ.copy()
  env.pop("FZF_DEFAULT_OPTS", None)
  env.pop("FZF_DEFAULT_OPTS_FILE", None)
  env["SHELL"] = "/bin/sh"
  result = subprocess.run(command, input=b"\0".join(records) + b"\0",
                          stdout=subprocess.PIPE, env=env, check=False)
  if result.returncode in (130, -2):
    fail("selection cancelled; no files were changed", 130)
  if result.returncode == 1:
    fail("no types selected; no files were changed", 1)
  if result.returncode != 0:
    fail(f"fzf failed (exit {result.returncode}); operation aborted")
  if not result.stdout:
    fail("no types selected; no files were changed", 1)
  if not result.stdout.endswith(b"\0"):
    fail("fzf returned an invalid type selection")
  selected = {row.partition(b"\t")[0]
              for row in result.stdout.split(b"\0") if row}
  if not selected or not selected.issubset(identities):
    fail("fzf returned an unknown type identity")
  extensions = {identities[identity] for identity in selected}
  return [path for path in candidates if file_type(path) in extensions]


def select_inputs(args: argparse.Namespace, sources: list[Path],
                  search_root: Path) -> list[Path]:
  if not args.interactive:
    return list(dict.fromkeys(sources))
  try:
    import file_picker
  except ModuleNotFoundError as error:
    if error.name != "file_picker":
      raise
    fail("interactive selection requires file_picker.py alongside this script")
  roots = sources or [search_root]
  if args.pick_types:
    roots = pick_type_candidates(args, roots, file_picker)
  return file_picker.select_files(args, sources=roots, multiple=True)


# -- Planning and display -----------------------------------------------------

def path_exists(path: Path) -> bool:
  return path.exists() or path.is_symlink()


def unique_target(path: Path, reserved: set[Path]) -> Path:
  index = 1
  candidate = path
  while path_exists(candidate) or candidate in reserved:
    candidate = path.with_name(f"{path.stem}_[{index}]{path.suffix}")
    index += 1
  return candidate


def archive_target(args: argparse.Namespace, target: Path) -> Path | None:
  if not target.suffix:
    target = target.with_name(target.name + ".7z")
  if target.suffix.casefold() != ".7z":
    fail("new archives use the 7z format; supply a .7z output name")
  if path_exists(target):
    if args.auto_rename:
      return unique_target(target, set())
    if args.skip_conflicts:
      return None
    if not args.overwrite:
      fail(f"archive already exists: {str(target)!r}; use --auto-rename, "
           "--skip-conflicts, or --overwrite")
    if target.is_dir() or target.is_symlink():
      fail(f"cannot replace an archive directory or symlink: {str(target)!r}")
  return target


def archive_base(args: argparse.Namespace, sources: list[Path],
                 raw_sources: list[Path], search_root: Path) -> Path:
  if args.base_dir:
    base = absolute_path(args.base_dir)
  elif args.interactive and not raw_sources:
    base = search_root
  else:
    base = Path(os.path.commonpath([str(path.parent) for path in raw_sources]))
  if not base.is_dir():
    fail(f"archive base is not a directory: {str(base)!r}")
  for source in sources:
    if not source.is_relative_to(base):
      fail(f"input is outside --base-dir: {str(source)!r}")
  return base


def extraction_targets(args: argparse.Namespace, sources: list[Path],
                        target: Path) -> list[tuple[Path, Path]]:
  if path_exists(target) and (not target.is_dir() or target.is_symlink()):
    fail(f"extraction destination must be a directory: {str(target)!r}")
  plans = []
  reserved: set[Path] = set()
  for source in sources:
    output = target if len(sources) == 1 else target / source.stem
    if output in reserved:
      if not args.auto_rename:
        fail("input archives have the same output directory name; "
             "use --auto-rename or extract them separately")
      output = unique_target(output, reserved)
    if path_exists(output) and (not output.is_dir() or output.is_symlink()):
      fail(f"extraction destination must be a directory: {str(output)!r}")
    reserved.add(output)
    plans.append((source, output))
  return plans


def display(message: str, console=None) -> None:
  if console:
    console.print(Text(message))
  else:
    print(message)


def print_plan(args: argparse.Namespace, plans: list[tuple[Path, Path]],
               base: Path | None, console=None) -> None:
  title = ("Dry-run " if args.dry_run else "") + args.action + " plan"
  rows = [(str(source), str(target)) for source, target in plans]
  if console:
    table = Table(title=title)
    table.add_column("Input", overflow="fold")
    table.add_column("Output", overflow="fold")
    for source, target in rows[:80]:
      table.add_row(Text(source), Text(target))
    if len(rows) > 80:
      table.add_row(f"... {len(rows) - 80} more inputs", "")
    console.print(table)
  else:
    print(title)
    for source, target in rows[:80]:
      print(f"  {source!r} -> {target!r}")
    if len(rows) > 80:
      print(f"  ... {len(rows) - 80} more inputs")
  if base:
    display(f"Archive path base: {str(base)!r}", console)
  mode = "overwrite" if args.overwrite else (
    "auto-rename" if args.auto_rename else (
      "skip" if args.skip_conflicts or args.action == "extract" else "abort"
    )
  )
  display(f"Conflict mode: {mode}", console)
  if args.action == "archive":
    display(f"Compression: {args.level} | Header encryption: {args.headers}",
            console)
    if args.delete_source_files:
      display("Source files: delete after archive verification and publication",
              console)
      if args.prune_empty_dirs:
        display("Source directories: prune empty directories after deletion",
                console)
  else:
    display("Layout: " + ("flat" if args.flatten else "preserve directories"),
            console)
  if args.password is not None or args.ask_password or args.headers == "on":
    display("Password: supplied" if args.password else "Password: private prompt",
            console)


# -- 7z commands and progress -------------------------------------------------

def password_for(args: argparse.Namespace) -> str | None:
  if args.password is not None:
    return args.password
  if not args.ask_password and args.headers != "on":
    return None
  if not sys.stdin.isatty():
    fail("password prompting requires a terminal; use --password for scripts")
  password = getpass.getpass("Archive password: ")
  if not password or "\0" in password:
    fail("the password must be nonempty and cannot contain NUL")
  if (args.action == "archive"
      and password != getpass.getpass("Confirm password: ")):
    fail("passwords do not match; no files were changed")
  return password


def common_switches(password: str | None) -> list[str]:
  switches = ["-spd", "-y", "-bso1", "-bse1", "-bsp1", "-sccUTF-8"]
  if password is not None:
    switches.append(f"-p{password}")
  return switches


def archive_command(binary: str, args: argparse.Namespace, sources: list[Path],
                    target: Path, base: Path, password: str | None,
                    exclusions: list[Path]) -> list[str]:
  command = [binary, "a", "-t7z", f"-mx={args.level}", "-sse", "-snl",
             *common_switches(password), f"-mhe={args.headers}"]
  for excluded in exclusions:
    if excluded.is_relative_to(base):
      command.append(f"-x!{excluded.relative_to(base)}")
  command.extend(["--", str(target)])
  # -- stops switch AND @listfile parsing; -spd makes wildcard names literal.
  command.extend(str(source.relative_to(base)) for source in sources)
  return command


def extract_command(binary: str, args: argparse.Namespace, source: Path,
                    target: Path, password: str | None) -> list[str]:
  conflict = "-aoa" if args.overwrite else (
    "-aou" if args.auto_rename else "-aos"
  )
  return [binary, "e" if args.flatten else "x", *common_switches(password),
          conflict, f"-o{target}", "--", str(source)]


def redacted_command(command: list[str]) -> str:
  result = []
  parsing = True
  for value in command:
    result.append("-p<redacted>" if parsing and value.startswith("-p") else value)
    if value == "--":
      parsing = False
  return shlex.join(result)


def run_7z(command: list[str], *, description: str, verbose: bool,
           password: str | None, console=None, cwd: Path | None = None) -> int:
  if verbose:
    display("Command: " + redacted_command(command), console)
  env = os.environ.copy()
  env["LC_ALL"] = "C.UTF-8"
  diagnostics: deque[str] = deque(maxlen=40)
  progress = None
  if console:
    progress = Progress(
      SpinnerColumn(), TextColumn("{task.description}", markup=False),
      BarColumn(), TaskProgressColumn(), TimeElapsedColumn(), console=console,
      refresh_per_second=4, disable=not console.is_terminal,
    )
    task = progress.add_task(description, total=100)
  else:
    print(description)
  process = subprocess.Popen(
    command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
  )

  def report(raw: bytes) -> None:
    line = raw.decode("utf-8", "backslashreplace").strip()
    if password:
      line = line.replace(password, "<redacted>")
    if not line:
      return
    percent = re.match(r"^(\d{1,3})%(?:\s|$)", line)
    if percent:
      if progress:
        progress.update(task, completed=min(int(percent[1]), 100))
      return
    diagnostics.append(line)
    if verbose:
      display(line, console)

  try:
    with process.stdout, selectors.DefaultSelector() as selector:
      selector.register(process.stdout, selectors.EVENT_READ)
      buffer = b""
      with progress if progress else nullcontext():
        while selector.get_map():
          for key, _ in selector.select(timeout=0.25):
            chunk = os.read(key.fd, 65536)
            if not chunk:
              selector.unregister(key.fileobj)
              continue
            parts = re.split(rb"[\r\n\x08]+", buffer + chunk)
            buffer = parts.pop()
            for raw in parts:
              report(raw)
          # Bound partial lines in malformed or unexpectedly large output.
          if len(buffer) > 65536:
            report(buffer)
            buffer = b""
        report(buffer)
        code = process.wait()
        if progress and code == 0:
          progress.update(task, completed=100)
  except BaseException:
    if process.poll() is None:
      process.terminate()
      try:
        process.wait(timeout=5)
      except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    raise
  if code != 0:
    if not verbose:
      for line in diagnostics:
        display(line, console)
    display(f"7z exited with code {code}. For encrypted inputs, supply "
            "--password or --ask-password.", console)
  return code if code >= 0 else 128 - code


# -- Execution ---------------------------------------------------------------

def source_state(path: Path) -> tuple[int, int, int, int, int, Path]:
  info = path.lstat()
  # Do not use ctime: unlinking one hard link changes the others' ctime.
  return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns,
          path.parent.resolve())


def snapshot_source_files(
  sources: list[Path], target: Path,
) -> dict[Path, tuple[int, int, int, int, int, Path]]:
  """Record cleanup candidates before compression; never follow symlinks."""
  snapshots = {}
  visited: set[Path] = set()
  pending = list(reversed(sources))
  output = target.parent.resolve() / target.name
  while pending:
    source = pending.pop()
    if source in visited:
      continue
    visited.add(source)
    if source.parent.resolve() / source.name == output:
      continue
    state = source_state(source)
    if stat.S_ISDIR(state[2]):
      pending.extend(sorted(source.iterdir(), reverse=True))
    elif stat.S_ISREG(state[2]) or stat.S_ISLNK(state[2]):
      snapshots[source] = state
    else:
      fail(f"cannot safely delete an unsupported source type: {str(source)!r}")
  return snapshots


def prune_empty_dirs(sources: list[Path], console=None) -> int:
  """Prune only within supplied roots, including the roots themselves."""
  removed = 0
  for source in dict.fromkeys(sources):
    if source.is_symlink() or not source.is_dir():
      continue
    for root, _, _ in os.walk(source, topdown=False, followlinks=False):
      try:
        Path(root).rmdir()
      except OSError:
        # Nonempty, inaccessible, or concurrently changed directories stay.
        continue
      removed += 1
  display(f"Pruned {removed} empty source directories.", console)
  return removed


def delete_source_files(
  snapshots: dict[Path, tuple[int, int, int, int, int, Path]], console=None,
) -> int:
  removed = 0
  kept = 0
  for source, expected in snapshots.items():
    try:
      if source_state(source) != expected:
        display(f"Kept changed source file: {str(source)!r}", console)
        kept += 1
        continue
      source.unlink()
    except FileNotFoundError:
      continue
    except OSError as error:
      display(f"Could not delete source file {str(source)!r}: {error}", console)
      kept += 1
      continue
    removed += 1
  display(f"Deleted {removed} archived source files.", console)
  if kept:
    display(f"Kept {kept} source files; the archive was created successfully.",
            console)
  return 1 if kept else 0


def create_archive(binary: str, args: argparse.Namespace, sources: list[Path],
                   target: Path, base: Path, password: str | None,
                   console=None) -> int:
  target.parent.mkdir(parents=True, exist_ok=True)
  # Stage beside the final output for a same-filesystem, atomic publication.
  # A failed compressor never replaces the user's existing archive.
  with tempfile.TemporaryDirectory(prefix=".rsafe-7z-", dir=target.parent) as raw:
    temporary = Path(raw)
    staged = temporary / "archive.7z"
    command = archive_command(binary, args, sources, staged, base, password,
                              [target, temporary])
    code = run_7z(command, description="Archiving", verbose=args.verbose,
                  password=password, console=console, cwd=base)
    if code:
      return code
    if args.delete_source_files:
      command = [binary, "t", *common_switches(password), "--", str(staged)]
      code = run_7z(command, description="Verifying archive",
                    verbose=args.verbose, password=password, console=console)
      if code:
        return code
    if args.overwrite:
      if target.is_dir() or target.is_symlink():
        fail("archive output became a directory or symlink; refusing replacement")
      os.replace(staged, target)
    else:
      # Hard-link publication fails if a competing writer created the target.
      os.link(staged, target)
  display(f"Created: {str(target)!r} ({target.stat().st_size} bytes)", console)
  return 0


def main(argv: list[str] | None = None) -> int:
  args = parse_args(argv)
  console = Console(highlight=False) if Console else None
  binary = shutil.which("7zz") or shutil.which("7z")
  if not binary:
    fail("7z/7zz was not found on PATH; on Arch: "
         "sudo pacman -S --needed 7zip python-rich")
  raw_sources = [absolute_path(path) for path in args.paths[:-1]]
  target = absolute_path(args.paths[-1])
  search_root = absolute_path(args.search_dir or ".")
  if args.interactive and not raw_sources and not search_root.is_dir():
    fail(f"search directory is not a directory: {str(search_root)!r}")
  sources = select_inputs(args, raw_sources, search_root)
  if not sources:
    fail("no inputs selected; no files were changed", 1)
  for source in sources:
    if args.action == "extract":
      if not source.is_file():
        fail(f"input archive is not a regular file: {str(source)!r}")
    elif not (source.is_file() or source.is_dir() or source.is_symlink()):
      fail(f"input is not a file or directory: {str(source)!r}")
  base = None
  if args.action == "archive":
    target = archive_target(args, target)
    if target is None:
      display("Skipped existing archive; no files were changed.", console)
      return 0
    if target in sources:
      fail("the archive output cannot also be an input")
    base = archive_base(args, sources, raw_sources, search_root)
    plans = [(source, target) for source in sources]
  else:
    plans = extraction_targets(args, sources, target)
  print_plan(args, plans, base, console)
  if args.dry_run:
    display("Dry run: no files were changed.", console)
    return 0
  password = password_for(args)
  started = time.monotonic()
  if args.action == "archive":
    snapshots = (snapshot_source_files(sources, target)
                 if args.delete_source_files else {})
    code = create_archive(binary, args, sources, target, base, password, console)
    if code == 0 and args.delete_source_files:
      code = delete_source_files(snapshots, console)
      if args.prune_empty_dirs:
        prune_empty_dirs(raw_sources or [search_root], console)
  else:
    code = 0
    for index, (source, output) in enumerate(plans, start=1):
      output.mkdir(parents=True, exist_ok=True)
      command = extract_command(binary, args, source, output, password)
      code = run_7z(command, description=f"Extracting {index}/{len(plans)}",
                    verbose=args.verbose, password=password, console=console)
      if code:
        break
      display(f"Extracted: {str(source)!r} -> {str(output)!r}", console)
  if code == 0:
    display(f"Finished in {time.monotonic() - started:.1f}s.", console)
  return code


if __name__ == "__main__":
  try:
    raise SystemExit(main())
  except KeyboardInterrupt:
    print("Operation cancelled.", file=sys.stderr)
    raise SystemExit(130)
  except (OSError, ValueError) as error:
    fail(str(error), 1)
