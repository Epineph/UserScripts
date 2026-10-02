#!/usr/bin/env python3
"""A verbose 7-Zip wrapper with Rich progress and hidden password entry.

Requires Python 3.10+ and a native 7zz, 7z, or 7za executable on Linux/macOS.
Rich is optional: without it, the wrapper prints periodic plain progress.
Run `r7z --help` or `r7z --long-help` for installation and usage examples.
"""

from __future__ import annotations

import argparse
import codecs
import errno
import getpass
import glob
import math
import os
import re
import selectors
import shlex
import shutil
import signal
import subprocess
import sys
import time
import warnings
from collections import deque
from pathlib import Path
from typing import Callable

VERSION = "1.0.0"
ALIASES = {
  "a": "create", "create": "create",
  "x": "extract", "extract": "extract",
  "t": "test", "test": "test",
}
PERCENT_RE = re.compile(r"^\s*(\d{1,3})%\s*(.*)$")
PASSWORD_RE = re.compile(
  r"^\s*(?:Enter|Reenter|Re-enter|Verify|Confirm) password"
  r"(?:\s*\([^\n]*\))?\s*:\s*$", re.IGNORECASE
)
ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
EXIT_MESSAGES = {
  1: "7-Zip reported a warning; inspect the messages above.",
  2: "7-Zip reported an error; inspect the messages above.",
  7: "7-Zip rejected a command-line option.",
  8: "7-Zip ran out of memory; reduce the compression level or threads.",
  255: "7-Zip stopped at the user's request.",
}

LONG_HELP = r"""
r7z: verbose 7-Zip archiving, extraction, and integrity testing
===========================================================

INSTALLATION (Arch Linux)
  sudo pacman -S --needed 7zip python-rich
  mkdir -p ~/.local/bin
  install -m 755 r7z.py ~/.local/bin/r7z

  Ensure ~/.local/bin is on PATH. For the current Bash/Zsh session:
    export PATH="$HOME/.local/bin:$PATH"

  Alternatively, install Rich inside your existing Python environment:
    python -m pip install rich
    python r7z.py --help

  Python 3.10+ is required. Rich is optional, but enables the live display.
  Linux and macOS are supported; native Windows is not supported.
  The engine search order is 7zz, 7z, then 7za. Override it with --engine.

COMMANDS
  r7z [a|create] [OPTIONS] INPUT ...   Create a NEW .7z archive.
  r7z x|extract [OPTIONS] ARCHIVE     Extract with stored relative paths.
  r7z t|test [OPTIONS] ARCHIVE        Test archive integrity; extract nothing.

  Creation is the default. When supplied, the command must come first.
  A file literally named a, x, t, create, extract, or test can be supplied
  as ./a, ./x, etc., or after --. Options can precede or follow inputs.

CREATING AN ARCHIVE
  Multiple files, directories, and shell-expanded globs are accepted:
    r7z Document1.pdf Document2.pdf -o documents.7z
    r7z -o research-backup ~/Documents ~/Pictures
    r7z -o pdfs.7z '*.pdf'
    r7z -o notes.7z 'notes with spaces.txt' './report[1].txt'
    r7z -o unusual-names.7z -- -report.txt @notes.txt

  A bare output name is placed in the directory where you invoked r7z.
  Relative output paths are also relative to that original directory:
    r7z -o backup.7z ~/Documents
    r7z -o ./Backups/backup.7z ~/Documents
    r7z -o ~/Backups/backup.7z ~/Documents
    r7z -o '$HOME/Backups/backup.7z' '$HOME/Documents'

  If no output is given, one input produces <input-stem>.7z, while several
  inputs produce archive.7z. A missing .7z extension is appended. An
  existing output directory receives the default archive name.
  Missing parent directories require --mkdir:
    r7z --mkdir -o ~/Backups/2026/october.7z ~/Documents

  Invalid paths cause an error instead of silently changing the destination.
  Existing archives are refused, including with --overwrite. Choose a new
  name: this wrapper does not update or replace existing archives.

PASSWORDS AND ENCRYPTED FILENAMES
  -p, --password, and --encrypt are equivalent prompt-only flags. They take
  NO password argument. On creation, enter and confirm a hidden passphrase:
    r7z --encrypt -o private.7z ~/Document1.pdf ~/Document2.pdf
    r7z -p -o private.7z ~/Documents
    r7z --encrypt-headers -o private.7z ~/Documents

  Encryption uses 7-Zip's 7z encryption. Filenames/headers are encrypted by
  default whenever encryption is selected. The startup summary states this.
  To encrypt file contents while leaving the archive's filenames visible:
    r7z --encrypt --no-header-encryption -o visible-names.7z ~/Documents

  Passphrases are never included in command arguments, environment variables,
  temporary files, or the printed command. Input goes to the child through
  a private terminal with echo disabled. The wrapper also refuses Python's
  visible-input fallback if a hidden prompt cannot be obtained.
  A terminal is required for password entry. Passwords are held in process
  memory during the operation. Newlines/control characters are unsupported;
  UTF-8 passphrases up to 1,000 encoded bytes are supported.

  Extraction and testing prompt automatically if 7-Zip needs a password.
  Supplying -p asks for it before starting instead:
    r7z x private.7z -o ~/Restored
    r7z x -p private.7z -o ~/Restored
    r7z t -p private.7z

  --encrypt-headers and --no-header-encryption apply only to creation.

COMPRESSION, THREADS, AND VERIFICATION
  The defaults are LZMA2, level 5, solid compression, and automatic threading.
  Level 0 stores data without compression; 1 is fast; 9 is memory intensive.
  Already compressed files usually gain little from higher levels:
    r7z --level 1 --threads 4 -o quick.7z ~/Documents
    r7z --level 9 --threads 4 --verify -o compact.7z ~/TextData
    r7z --level 0 -o media.7z ~/Videos
    r7z --no-solid -o separate-files.7z ~/Documents

  Solid compression can compress related files better. Disabling it can
  make extraction of an individual file faster. --threads is passed to the
  engine; actual thread use also depends on its compression method.
  --verify runs a separate integrity test after successful creation. For an
  encrypted archive it reuses the hidden passphrase without prompting again.

EXTRACTION
  Without -o, extraction goes to ./<archive-stem>/:
    r7z x documents.7z
    r7z x documents.7z -o ~/Restored
    r7z x --overwrite documents.7z -o ~/Restored

  Existing files are SKIPPED by default. --overwrite replaces extracted
  files with the same names. Extraction creates its output directories.
  A skipped file is not verified against the archived version.

PATHS, SYMLINKS, AND GLOBS
  ~, ~user, $HOME, and ${HOME} are expanded by the wrapper. Quote paths with
  spaces. Quoting '$HOME/...' is valid even if your shell leaves it literal.
  Unmatched input patterns fail. An existing literal path takes precedence
  over pattern expansion, so filenames containing [brackets] remain usable.

  Archive entries are relative to the common parent of the selected inputs.
  For example, ~/Work/a.txt and ~/Notes/b.txt retain Work/ and Notes/.
  One selected directory retains its own directory name. Symbolic links
  are stored as links (-snl), rather than deliberately following them.
  The new output archive is excluded if it sits inside an input directory.
  Inputs are kept; source files are never deleted. This is not a snapshot:
  files changing during compression can cause warnings or inconsistent data.

PROGRESS AND ETA
  The bar uses 7-Zip's reported percentage, rather than archive size growth.
  Before percentages become available, the display shows an indeterminate
  scan/work phase. ETA waits for at least three seconds and a progress
  increase, then estimates from approximately the last 30 seconds:
    ETA = (100 - current percentage) / recent percentage-points per second

  Delays with no percentage increase lengthen the estimate. A phase reset
  resets the estimator. Scanning and password entry do not seed the work ETA.
  File types, compression ratios, storage, and final writes can change the
  speed; an ETA is approximate, especially early in the operation.
  A displayed 100% is not success: success requires the engine's exit code.

VERBOSITY AND PLAIN OUTPUT
  Verbose engine output is the default (--verbose 1). Level 0 keeps engine
  summaries; levels 2 and 3 show additional engine detail:
    r7z --verbose 2 --verify -o detailed.7z ~/Documents
    r7z --no-progress -o backup.7z ~/Documents > archive.log 2>&1
    r7z --no-color -o backup.7z ~/Documents
    r7z --engine /usr/bin/7z -o backup.7z ~/Documents

  Redirected output uses plain text without animated terminal controls.
  Without Rich, periodic plain progress is also available on a terminal.
  --no-progress suppresses progress only, while keeping verbose messages.

EXIT STATUS AND INTERRUPTION
  0: success. Native 7-Zip statuses are preserved: 1 warning, 2 fatal error,
  7 command-line error, 8 insufficient memory, and 255 user cancellation.
  Wrapper validation errors use 2; Ctrl+C uses 130.
  Interrupted/failed creation can leave a partial archive. It is reported
  and retained for inspection; use a new output name for the next attempt.
  Do not treat an archive with errors/warnings as a confirmed complete backup.

HELP
  r7z --help          Concise option reference.
  r7z --long-help     This guide, including practical examples.
  r7z --version      Wrapper version.

  Ordinary user files do not require sudo. Run the wrapper normally so that
  your own ~, $HOME, environment, and file ownership are used.
""".strip()


# -----------------------------------------------------------------------------
# CLI arguments and path handling
# -----------------------------------------------------------------------------

class UserError(Exception):
  """An actionable error that does not need a Python traceback."""


def build_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(
    prog="r7z", allow_abbrev=False,
    usage="%(prog)s [a|x|t] [options] PATH [PATH ...]",
    description=(
      "Create .7z archives (default), extract (x), or test integrity (t). "
      "Verbose output, estimated ETA, and hidden password prompts."
    ),
    epilog=(
      "Examples: r7z -p -o private.7z ~/Documents | "
      "r7z x private.7z -o ~/Restored | r7z t private.7z\n"
      "Use --long-help for installation, encryption details, and more examples."
    ),
    formatter_class=argparse.RawDescriptionHelpFormatter,
  )
  parser.add_argument("paths", nargs="*", metavar="PATH",
                      help="input files/directories; one archive for x or t")
  parser.add_argument("--long-help", action="store_true",
                      help="show the extended guide with practical examples")
  parser.add_argument("--version", action="version",
                      version=f"r7z {VERSION}")
  parser.add_argument("-o", "--output", metavar="PATH",
                      help="archive name/path; extraction directory for x")
  parser.add_argument("-p", "--password", "--encrypt", action="store_true",
                      help="hidden password prompt; encrypt on creation")
  headers = parser.add_mutually_exclusive_group()
  headers.add_argument("--encrypt-headers", dest="header_encryption",
                       action="store_true",
                       help="encrypt contents and filenames (implies -p)")
  headers.add_argument("--no-header-encryption", dest="header_encryption",
                       action="store_false",
                       help="with -p, encrypt contents but expose filenames")
  parser.set_defaults(header_encryption=None)
  parser.add_argument("-l", "--level", type=int, choices=range(10),
                      default=None, metavar="0-9",
                      help="creation: compression level (default: 5)")
  parser.add_argument("-j", "--threads", type=int, metavar="N",
                      help="creation: maximum requested threads (default: auto)")
  parser.add_argument("--no-solid", action="store_true",
                      help="creation: disable solid compression")
  parser.add_argument("--verify", action="store_true",
                      help="creation: also test the completed archive")
  parser.add_argument("--mkdir", action="store_true",
                      help="creation: create missing output parent directories")
  parser.add_argument("--overwrite", action="store_true",
                      help="extraction: overwrite files; default is to skip")
  parser.add_argument("-v", "--verbose", type=int, choices=range(4),
                      default=1, metavar="0-3",
                      help="engine log level (default: 1, verbose)")
  parser.add_argument("--engine", metavar="PATH",
                      help="choose the 7-Zip executable explicitly")
  parser.add_argument("--no-progress", action="store_true",
                      help="hide the progress display; keep engine messages")
  parser.add_argument("--no-color", action="store_true",
                      help="disable coloured terminal output")
  return parser


def expanded_path(value: str) -> Path:
  if not value:
    raise UserError("A path cannot be empty.")
  expanded = os.path.expanduser(os.path.expandvars(value))
  return Path(os.path.abspath(expanded))


def input_paths(values: list[str]) -> list[Path]:
  """Expand paths/globs while retaining symlinks and literal bracket names."""
  result: list[Path] = []
  for value in values:
    candidate = expanded_path(value)
    if os.path.lexists(candidate):
      matches = [str(candidate)]
    else:
      matches = (
        glob.glob(str(candidate)) if glob.has_magic(str(candidate)) else []
      )
    if not matches:
      raise UserError(f"No input matched: {value}")
    for match in sorted(matches):
      path = Path(os.path.abspath(match))
      if not (path.is_file() or path.is_dir() or path.is_symlink()):
        raise UserError(
          f"Input is not a regular file, directory, or link: {path}"
        )
      if path not in result:
        result.append(path)
  return result


def find_engine(value: str | None) -> str:
  candidates = [value] if value else ["7zz", "7z", "7za"]
  for candidate in candidates:
    if candidate is None:
      continue
    name = os.path.expanduser(os.path.expandvars(candidate))
    found = shutil.which(name)
    if found:
      return os.path.abspath(found)
  raise UserError(
    "7-Zip executable not found. On Arch: "
    "sudo pacman -S --needed 7zip; or supply --engine PATH."
  )


def default_name(paths: list[Path]) -> str:
  if len(paths) != 1:
    return "archive.7z"
  path = paths[0]
  stem = path.name if path.is_dir() else path.stem
  return f"{stem or 'archive'}.7z"


def archive_output(args: argparse.Namespace, paths: list[Path]) -> Path:
  name = default_name(paths)
  output = expanded_path(args.output) if args.output else Path.cwd() / name
  if output.is_dir():
    output /= name
  elif args.output and args.output.endswith(os.sep):
    output /= name
  if output.suffix.lower() != ".7z":
    output = output.with_name(output.name + ".7z")
  if os.path.lexists(output):
    raise UserError(
      f"Output already exists; choose a new archive name: {output}"
    )
  if not output.parent.is_dir():
    if args.mkdir:
      output.parent.mkdir(parents=True, exist_ok=True)
    else:
      raise UserError(
        f"Output parent does not exist: {output.parent}; use --mkdir."
      )
  return output


def validate_options(args: argparse.Namespace, mode: str) -> None:
  if args.threads is not None and args.threads < 1:
    raise UserError("--threads must be at least 1.")
  if mode != "create" and any((
    args.level is not None, args.threads is not None, args.no_solid,
    args.verify, args.mkdir, args.header_encryption is not None,
  )):
    raise UserError("Compression/header/verify/mkdir options apply to creation.")
  if mode != "extract" and args.overwrite:
    raise UserError("--overwrite applies only to extraction.")
  if mode == "test" and args.output is not None:
    raise UserError("Testing writes nothing; omit --output.")
  if args.header_encryption is False and not args.password:
    raise UserError("--no-header-encryption requires --encrypt (or -p).")


# -----------------------------------------------------------------------------
# Progress estimator and optional Rich presentation
# -----------------------------------------------------------------------------

def clean_text(value: str) -> str:
  value = ANSI_RE.sub("", value)
  return "".join(ch for ch in value if ch >= " " and ch != "\x7f")


def duration(seconds: float | None) -> str:
  if seconds is None or not math.isfinite(seconds):
    return "--:--"
  whole = max(0, math.ceil(seconds))
  hours, remainder = divmod(whole, 3600)
  minutes, secs = divmod(remainder, 60)
  if hours:
    return f"{hours:d}:{minutes:02d}:{secs:02d}"
  return f"{minutes:02d}:{secs:02d}"


def human_bytes(size: int) -> str:
  number = float(size)
  for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
    if number < 1024 or unit == "TiB":
      return f"{number:,.1f} {unit}" if unit != "B" else f"{size:,} B"
    number /= 1024
  return str(size)


class Estimator:
  """Estimate from reported work percentages, including current plateaus."""

  def __init__(self) -> None:
    self.samples: deque[tuple[float, float]] = deque()
    self.percent: float | None = None

  def reset(self) -> None:
    self.samples.clear()
    self.percent = None

  def update(self, percent: float, now: float) -> None:
    if self.percent is not None and percent < self.percent:
      self.reset()
    if self.percent != percent:
      self.samples.append((now, percent))
      self.percent = percent
    # Retain one sample before the window to keep a usable interval.
    while len(self.samples) > 2 and self.samples[1][0] < now - 30:
      self.samples.popleft()

  def remaining(self, now: float) -> float | None:
    if self.percent is None or len(self.samples) < 2:
      return None
    if self.percent >= 100:
      return 0
    start, initial = self.samples[0]
    elapsed = now - start
    change = self.percent - initial
    if elapsed < 3 or change < 1:
      return None
    return (100 - self.percent) * elapsed / change


class Display:
  """Render live Rich progress, or readable periodic output without Rich."""

  def __init__(self, args: argparse.Namespace) -> None:
    self.args = args
    self.console = None
    self.progress = None
    self.task = None
    self.active = False
    self.started = time.monotonic()
    self.last_plain = self.started
    self.phase = "Starting"
    self.estimator = Estimator()
    try:
      from rich.console import Console
      from rich.progress import BarColumn, Progress, SpinnerColumn, TextColumn
      self.console = Console(
        no_color=args.no_color, highlight=False,
        color_system=None if args.no_color else "auto",
      )
      if self.console.is_terminal and not args.no_progress:
        self.progress = Progress(
          SpinnerColumn(), TextColumn("{task.description}"),
          BarColumn(), TextColumn("{task.fields[percent_label]}"),
          TextColumn("elapsed {task.fields[elapsed_label]}"),
          TextColumn("ETA {task.fields[eta_label]}"),
          console=self.console, auto_refresh=False,
        )
    except ImportError:
      pass

  def log(self, message: str = "", style: str | None = None) -> None:
    safe = clean_text(message)
    if self.console is not None:
      self.console.print(safe, markup=False, style=style)
    else:
      print(safe, flush=True)

  def begin(self, phase: str) -> None:
    self.phase = phase
    self.estimator.reset()
    self.started = time.monotonic()
    self.last_plain = self.started
    if self.progress is not None:
      if self.task is not None:
        self.progress.remove_task(self.task)
      self.task = self.progress.add_task(
        phase, total=None, percent_label=" --%",
        elapsed_label="00:00", eta_label="--:--",
      )
      self.progress.start()
      self.active = True

  def pause(self) -> None:
    if self.progress is not None and self.active:
      self.progress.stop()
      self.active = False

  def resume(self) -> None:
    self.estimator.reset()
    if self.progress is not None and not self.active:
      self.progress.start()
      self.active = True

  def percentage(self, percent: int, phase: str) -> None:
    self.phase = phase
    self.estimator.update(min(100, percent), time.monotonic())
    self.refresh()

  def refresh(self) -> None:
    now = time.monotonic()
    percent = self.estimator.percent
    eta = self.estimator.remaining(now)
    label = f"{percent:3.0f}%" if percent is not None else " --%"
    eta_label = ("~" if eta is not None else "") + duration(eta)
    elapsed_label = duration(now - self.started)
    if self.progress is not None and self.active:
      self.progress.update(
        self.task, description=self.phase,
        total=100 if percent is not None else None,
        completed=percent or 0, percent_label=label,
        elapsed_label=elapsed_label, eta_label=eta_label,
      )
      self.progress.refresh()
    elif not self.args.no_progress and now - self.last_plain >= 5:
      self.log(
        f"{self.phase}: {label} | elapsed {elapsed_label} | ETA {eta_label}"
      )
      self.last_plain = now

  def finish(self, success: bool) -> None:
    if success and self.estimator.percent is not None:
      self.estimator.update(100, time.monotonic())
      self.refresh()
    self.pause()


# -----------------------------------------------------------------------------
# Hidden passphrases and the child process output stream
# -----------------------------------------------------------------------------

class Secret:
  """Hold the passphrase in memory; send it only when the engine asks."""

  def __init__(self) -> None:
    self.value: str | None = None

  def acquire(self, confirm: bool = False) -> None:
    with warnings.catch_warnings():
      warnings.simplefilter("error", getpass.GetPassWarning)
      try:
        value = getpass.getpass("Passphrase (hidden): ")
        if not value:
          raise UserError("An empty passphrase is not allowed.")
        if any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
          raise UserError("Passphrases cannot contain control characters.")
        if len(value.encode("utf-8")) > 1000:
          raise UserError("Passphrase exceeds 1,000 UTF-8 bytes.")
        if confirm and value != getpass.getpass("Confirm passphrase (hidden): "):
          raise UserError("Passphrases did not match; nothing was archived.")
      except (getpass.GetPassWarning, EOFError, OSError) as exc:
        raise UserError(
          "Hidden password entry needs a terminal. Run interactively."
        ) from exc
    self.value = value

  def send(self, master: int, display: Display) -> None:
    if self.value is None:
      display.pause()
      display.log("7-Zip requires a passphrase; terminal input will be hidden.")
      try:
        self.acquire()
      finally:
        display.resume()
    import termios
    attributes = termios.tcgetattr(master)
    attributes[3] &= ~(termios.ECHO | termios.ECHONL)
    termios.tcsetattr(master, termios.TCSANOW, attributes)
    data = (self.value + "\n").encode("utf-8")
    while data:
      written = os.write(master, data)
      data = data[written:]


class TerminalLines:
  """Interpret 7-Zip's backspace/carriage-return progress as terminal text."""

  def __init__(self, callback: Callable[[str, bool], None]) -> None:
    self.callback = callback
    self.characters: list[str] = []
    self.cursor = 0

  def feed(self, text: str) -> None:
    for char in text:
      if char == "\n":
        self.callback("".join(self.characters).rstrip(), True)
        self.characters.clear()
        self.cursor = 0
      elif char == "\r":
        self.cursor = 0
      elif char == "\b":
        self.cursor = max(0, self.cursor - 1)
      elif char >= " " or char == "\t":
        if self.cursor < len(self.characters):
          self.characters[self.cursor] = char
        else:
          self.characters.append(char)
        self.cursor += 1
    self.callback("".join(self.characters).rstrip(), False)

  def flush(self) -> None:
    if self.characters:
      self.callback("".join(self.characters).rstrip(), True)
      self.characters.clear()
      self.cursor = 0


def stop_child(process: subprocess.Popen) -> None:
  """Stop the isolated child process group and reap it before returning."""
  for sig, timeout in ((signal.SIGINT, 3), (signal.SIGTERM, 2)):
    if process.poll() is not None:
      return
    try:
      os.killpg(process.pid, sig)
    except ProcessLookupError:
      return
    try:
      process.wait(timeout=timeout)
      return
    except subprocess.TimeoutExpired:
      continue
  if process.poll() is None:
    try:
      os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
      pass
    process.wait()


def run_engine(
  command: list[str], cwd: Path, phase: str,
  display: Display, secret: Secret,
) -> int:
  """Stream native progress and logs; the password never enters argv."""
  import pty
  import termios
  master, slave = pty.openpty()
  process = None
  password_requests = 0
  prompt_handled = False
  scan_seen = False
  selector = selectors.DefaultSelector()
  decoder = codecs.getincrementaldecoder("utf-8")("replace")

  def observe(line: str, complete: bool) -> None:
    nonlocal password_requests, prompt_handled, scan_seen
    if PASSWORD_RE.fullmatch(line):
      if not prompt_handled:
        password_requests += 1
        if password_requests > 4:
          raise UserError("The engine requested a password too many times.")
        display.log("Password request handled with hidden input.", "dim")
        secret.send(master, display)
        prompt_handled = True
      return
    if line.strip():
      prompt_handled = False
    progress = PERCENT_RE.match(line)
    if progress and int(progress.group(1)) <= 100:
      display.percentage(int(progress.group(1)), phase)
      return
    if re.match(r"^\s*\d+[KMG]?\s+Scan\b", line):
      display.phase = "Scanning"
      if not scan_seen:
        display.estimator.reset()
        scan_seen = True
      display.refresh()
      return
    if complete:
      display.log(line)

  try:
    attributes = termios.tcgetattr(slave)
    attributes[3] &= ~(termios.ECHO | termios.ECHONL)
    termios.tcsetattr(slave, termios.TCSANOW, attributes)
    display.log("Command: " + shlex.join(command), "dim")
    display.log("Working directory: " + str(cwd), "dim")
    process = subprocess.Popen(
      command, cwd=cwd, stdin=slave, stdout=subprocess.PIPE,
      stderr=subprocess.STDOUT, start_new_session=True, bufsize=0,
    )
    os.close(slave)
    slave = -1
    selector.register(process.stdout, selectors.EVENT_READ)
    lines = TerminalLines(observe)
    display.begin("Scanning" if phase == "Compressing" else phase)
    while selector.get_map():
      events = selector.select(timeout=0.2)
      for key, _ in events:
        try:
          data = os.read(key.fd, 65536)
        except OSError as exc:
          if exc.errno == errno.EINTR:
            continue
          raise
        if data:
          lines.feed(decoder.decode(data))
        else:
          selector.unregister(key.fileobj)
      display.refresh()
    lines.feed(decoder.decode(b"", final=True))
    lines.flush()
    result = process.wait()
    display.finish(result == 0)
    return result if result >= 0 else 128 - result
  finally:
    display.pause()
    if process is not None:
      stop_child(process)
      if process.stdout is not None:
        process.stdout.close()
    selector.close()
    if slave != -1:
      os.close(slave)
    os.close(master)


# -----------------------------------------------------------------------------
# Native commands and the top-level workflow
# -----------------------------------------------------------------------------

def base_command(engine: str, verb: str, args: argparse.Namespace) -> list[str]:
  return [
    engine, verb, f"-bb{args.verbose}", "-bso1", "-bse1", "-bsp1",
    "-sccUTF-8", "-spd", "-y",
  ]


def main(argv: list[str] | None = None) -> int:
  values = list(sys.argv[1:] if argv is None else argv)
  mode = ALIASES.get(values[0], "create") if values else "create"
  if values and values[0] in ALIASES:
    values.pop(0)
  parser = build_parser()
  args = parser.parse_intermixed_args(values)
  if args.long_help:
    print(LONG_HELP)
    return 0
  if not args.paths:
    parser.error("supply at least one input; use --long-help for examples")
  display = Display(args)
  secret = Secret()
  created: Path | None = None
  began = time.monotonic()
  try:
    if os.name != "posix":
      raise UserError("This wrapper requires Linux or macOS.")
    validate_options(args, mode)
    engine = find_engine(args.engine)
    paths = input_paths(args.paths)
    encrypt = args.password or args.header_encryption is True
    headers = encrypt and args.header_encryption is not False
    output = None
    cwd = Path.cwd()

    display.log(f"r7z {VERSION} | {mode}", "bold cyan")
    display.log("Engine: " + engine)
    for path in paths:
      display.log("Input:  " + str(path))

    if mode == "create":
      output = archive_output(args, paths)
      parents = [str(path.parent) for path in paths]
      cwd = Path(os.path.commonpath(parents))
      level = args.level if args.level is not None else 5
      display.log("Output: " + str(output))
      display.log(
        f"Compression: LZMA2, level {level}, "
        f"solid {'off' if args.no_solid else 'on'}, "
        f"threads {args.threads or 'auto'}"
      )
      display.log(
        "Encryption: file contents and filenames/headers; hidden passphrase."
        if headers else
        "Encryption: file contents; filenames visible; hidden passphrase."
        if encrypt else "Encryption: off."
      )
      if encrypt:
        secret.acquire(confirm=True)
      # Reserve the name exclusively so a competing creation cannot update it.
      # 7-Zip receives a valid empty 7z archive, rather than a zero-byte file.
      with output.open("xb") as reserved:
        reserved.write(bytes.fromhex(
          "377abcaf271c00048d9bd50f0000000000000000000000000000000000000000"
        ))
      created = output
      command = base_command(engine, "a", args)
      command += [
        "-t7z", "-m0=LZMA2", f"-mx={level}",
        f"-mmt={args.threads or 'on'}",
        "-ms=off" if args.no_solid else "-ms=on", "-snl", "-sse",
      ]
      if encrypt:
        command += ["-p", "-mhe=on" if headers else "-mhe=off"]
      # The reserved empty archive must not become one of its own inputs.
      try:
        relative_output = output.relative_to(cwd)
      except ValueError:
        relative_output = None
      if relative_output is not None:
        command.append("-x!" + str(relative_output))
      command += ["--", str(output)]
      command += [str(path.relative_to(cwd)) for path in paths]
      code = run_engine(command, cwd, "Compressing", display, secret)
      if code == 0 and args.verify:
        display.log("Verifying the completed archive...", "bold cyan")
        check = base_command(engine, "t", args)
        # On extraction/testing, native bare -p can mean an empty password.
        # Omit it so the engine actually requests the cached hidden secret.
        check += ["--", str(output)]
        code = run_engine(check, Path.cwd(), "Verifying", display, secret)
    else:
      if len(paths) != 1 or not paths[0].is_file():
        raise UserError("Extraction/testing requires exactly one archive file.")
      archive = paths[0]
      if args.password:
        display.log("Password entry: hidden; prompted before starting.")
        secret.acquire()
      else:
        display.log("Password entry: hidden; prompted automatically if needed.")
      command = base_command(engine, "x" if mode == "extract" else "t", args)
      if mode == "extract":
        output = (expanded_path(args.output) if args.output else
                  Path.cwd() / archive.stem)
        if output.exists() and not output.is_dir():
          raise UserError(f"Extraction destination is not a directory: {output}")
        output.mkdir(parents=True, exist_ok=True)
        display.log("Output: " + str(output))
        display.log(
          "Existing extracted files: " +
          ("overwrite" if args.overwrite else "skip")
        )
        command += [f"-o{output}", "-aoa" if args.overwrite else "-aos"]
      command += ["--", str(archive)]
      phase = "Extracting" if mode == "extract" else "Testing"
      code = run_engine(command, cwd, phase, display, secret)

    elapsed = duration(time.monotonic() - began)
    if code == 0:
      display.log(f"Success | elapsed {elapsed}", "bold green")
      if output is not None:
        suffix = f" ({human_bytes(output.stat().st_size)})" if created else ""
        display.log("Saved: " + str(output) + suffix)
    else:
      message = EXIT_MESSAGES.get(code, f"Engine exited with status {code}.")
      display.log(f"Status {code} | {message}", "bold red")
      if created is not None and created.exists():
        display.log("Archive may be incomplete; retained at: " + str(created))
    return code
  except KeyboardInterrupt:
    display.pause()
    display.log("Interrupted.", "bold yellow")
    if created is not None and created.exists():
      display.log("Partial archive retained at: " + str(created))
    return 130
  except (UserError, OSError, ValueError) as exc:
    display.pause()
    display.log("Error: " + str(exc), "bold red")
    if created is not None and created.exists():
      display.log("Archive may be incomplete; retained at: " + str(created))
    return 2
  finally:
    secret.value = None


if __name__ == "__main__":
  sys.exit(main())
