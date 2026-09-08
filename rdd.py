#!/usr/bin/env python3
"""Rich front end for GNU dd.

`rdd` keeps GNU dd as the transfer engine, but adds device inspection,
destructive-write safeguards, a live progress display, throughput history,
and optional post-write SHA-256 verification.

Linux only. Requires GNU coreutils/util-linux and the Python package `rich`.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import queue
import re
import shlex
import shutil
import stat
import subprocess
import sys
import threading
import time
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

try:
  from rich.console import Console, Group
  from rich.live import Live
  from rich.panel import Panel
  from rich.progress import (
    BarColumn,
    DownloadColumn,
    Progress,
    SpinnerColumn,
    TaskProgressColumn,
    TextColumn,
    TimeRemainingColumn,
    TransferSpeedColumn,
  )
  from rich.table import Table
  from rich.text import Text
except ImportError:
  print(
    "rdd requires the Python package 'rich'.\n"
    "Install it with your package manager or: python -m pip install rich",
    file=sys.stderr,
  )
  raise SystemExit(2)


APP = "rdd"
VERSION = "0.1.0"
SPARK_CHARS = "▁▂▃▄▅▆▇█"
DD_PROGRESS_RE = re.compile(r"^\s*(\d+)\s+bytes\b")
console = Console()


# -- Data types ----------------------------------------------------------------

@dataclass
class Endpoint:
  """Resolved information about one transfer endpoint."""

  path: Path
  kind: str
  size: int | None
  block: bool
  exists: bool
  metadata: dict


# -- Formatting ----------------------------------------------------------------

def human_bytes(value: float | int | None) -> str:
  """Format a byte count using IEC binary units."""
  if value is None:
    return "unknown"

  amount = float(value)
  units = ("B", "KiB", "MiB", "GiB", "TiB", "PiB")

  for unit in units:
    if abs(amount) < 1024.0 or unit == units[-1]:
      if unit == "B":
        return f"{amount:.0f} {unit}"
      return f"{amount:.2f} {unit}"
    amount /= 1024.0

  return f"{amount:.2f} PiB"


def human_seconds(value: float | None) -> str:
  """Format seconds as a compact duration."""
  if value is None or value < 0:
    return "unknown"

  seconds = int(round(value))
  hours, seconds = divmod(seconds, 3600)
  minutes, seconds = divmod(seconds, 60)

  if hours:
    return f"{hours:d}h {minutes:02d}m {seconds:02d}s"
  if minutes:
    return f"{minutes:d}m {seconds:02d}s"
  return f"{seconds:d}s"


def sparkline(values: deque[float]) -> str:
  """Return a small Unicode throughput history chart."""
  if not values:
    return "·"

  maximum = max(values)
  if maximum <= 0:
    return SPARK_CHARS[0] * len(values)

  output = []
  last = len(SPARK_CHARS) - 1

  for value in values:
    index = min(last, int((value / maximum) * last))
    output.append(SPARK_CHARS[index])

  return "".join(output)


# -- System inspection ----------------------------------------------------------

def require_command(name: str) -> str:
  """Return an executable path or exit with a useful error."""
  resolved = shutil.which(name)
  if resolved is None:
    console.print(f"[bold red]Missing required command:[/] {name}")
    raise SystemExit(2)
  return resolved


def is_block_device(path: Path) -> bool:
  """Return True when path exists and is a block device."""
  try:
    return stat.S_ISBLK(path.stat().st_mode)
  except FileNotFoundError:
    return False


def block_size(path: Path) -> int:
  """Read the byte capacity of a block device."""
  blockdev = require_command("blockdev")
  result = subprocess.run(
    [blockdev, "--getsize64", str(path)],
    check=True,
    capture_output=True,
    text=True,
  )
  return int(result.stdout.strip())


def lsblk_json(path: Path | None = None, *, top_only: bool = False) -> dict:
  """Return selected lsblk data as JSON."""
  lsblk = require_command("lsblk")
  command = [
    lsblk,
    "--json",
    "--bytes",
    "--output",
    "NAME,PATH,TYPE,SIZE,MODEL,SERIAL,TRAN,RO,RM,MOUNTPOINTS",
  ]

  if top_only:
    command.append("--nodeps")

  if path is not None:
    command.append(str(path))

  result = subprocess.run(
    command,
    check=True,
    capture_output=True,
    text=True,
  )
  return json.loads(result.stdout)


def flatten_nodes(nodes: list[dict]) -> list[dict]:
  """Flatten an lsblk tree."""
  output: list[dict] = []

  for node in nodes:
    output.append(node)
    output.extend(flatten_nodes(node.get("children", [])))

  return output


def inspect_block(path: Path) -> dict:
  """Return metadata for one block device."""
  data = lsblk_json(path)
  devices = data.get("blockdevices", [])

  if not devices:
    return {}

  root = devices[0]
  nodes = flatten_nodes(devices)
  mounts: list[str] = []

  for node in nodes:
    for mount in node.get("mountpoints") or []:
      if mount:
        mounts.append(str(mount))

  return {
    "name": root.get("name"),
    "path": root.get("path") or str(path),
    "type": root.get("type"),
    "size": root.get("size"),
    "model": (root.get("model") or "").strip(),
    "serial": (root.get("serial") or "").strip(),
    "transport": root.get("tran") or "",
    "read_only": bool(root.get("ro")),
    "removable": bool(root.get("rm")),
    "mounts": sorted(set(mounts)),
  }


def resolve_endpoint(raw: str, *, source: bool) -> Endpoint:
  """Resolve path type, capacity, and block metadata."""
  path = Path(raw).expanduser()
  exists = path.exists()
  block = is_block_device(path)
  metadata: dict = {}

  if source and not exists:
    console.print(f"[bold red]Source does not exist:[/] {path}")
    raise SystemExit(2)

  if exists and path.is_dir():
    console.print(f"[bold red]Directories are not valid endpoints:[/] {path}")
    raise SystemExit(2)

  if block:
    size = block_size(path)
    metadata = inspect_block(path)
    kind = metadata.get("type") or "block device"
  elif exists:
    size = path.stat().st_size
    kind = "file"
  else:
    size = None
    kind = "new file"

  return Endpoint(
    path=path,
    kind=kind,
    size=size,
    block=block,
    exists=exists,
    metadata=metadata,
  )


def endpoint_panel(title: str, endpoint: Endpoint) -> Panel:
  """Create a compact endpoint information panel."""
  table = Table.grid(padding=(0, 2))
  table.add_column(style="bold")
  table.add_column()

  table.add_row("Path", str(endpoint.path))
  table.add_row("Kind", endpoint.kind)
  table.add_row("Size", human_bytes(endpoint.size))

  if endpoint.block:
    meta = endpoint.metadata
    table.add_row("Model", meta.get("model") or "—")
    table.add_row("Serial", meta.get("serial") or "—")
    table.add_row("Transport", meta.get("transport") or "—")
    table.add_row("Removable", "yes" if meta.get("removable") else "no")
    mounts = ", ".join(meta.get("mounts", [])) or "none"
    table.add_row("Mounted", mounts)

  return Panel(table, title=title, border_style="cyan")


def list_devices() -> None:
  """Print a readable block-device inventory."""
  data = lsblk_json(top_only=True)
  rows = data.get("blockdevices", [])

  table = Table(title="Block devices")
  table.add_column("Path", style="bold")
  table.add_column("Type")
  table.add_column("Size", justify="right")
  table.add_column("Transport")
  table.add_column("Model")
  table.add_column("Removable", justify="center")
  table.add_column("RO", justify="center")

  for row in rows:
    table.add_row(
      str(row.get("path") or ""),
      str(row.get("type") or ""),
      human_bytes(row.get("size")),
      str(row.get("tran") or ""),
      str(row.get("model") or "").strip(),
      "yes" if row.get("rm") else "no",
      "yes" if row.get("ro") else "no",
    )

  console.print(table)


# -- Validation and safety ------------------------------------------------------

def validate_transfer(source: Endpoint, target: Endpoint) -> None:
  """Reject unsafe or impossible transfers before invoking dd."""
  if source.path.resolve() == target.path.resolve():
    console.print("[bold red]Source and target resolve to the same path.[/]")
    raise SystemExit(2)

  if target.block:
    mounts = target.metadata.get("mounts", [])

    if target.metadata.get("read_only"):
      console.print("[bold red]Target block device is read-only.[/]")
      raise SystemExit(2)

    if mounts:
      console.print(
        "[bold red]Refusing to write to a mounted block device.[/]\n"
        f"Mounted filesystems: {', '.join(mounts)}"
      )
      console.print("Unmount the target and run the command again.")
      raise SystemExit(2)

    if os.geteuid() != 0:
      console.print(
        "[bold red]Writing to a block device normally requires root.[/]\n"
        "Run the same command through sudo."
      )
      raise SystemExit(2)

  if source.size is not None and target.block:
    if target.size is not None and source.size > target.size:
      console.print(
        "[bold red]Source is larger than the target device.[/]\n"
        f"Source: {human_bytes(source.size)}\n"
        f"Target: {human_bytes(target.size)}"
      )
      raise SystemExit(2)

  if not target.block and source.size is not None:
    parent = target.path.parent
    while not parent.exists() and parent != parent.parent:
      parent = parent.parent

    free = shutil.disk_usage(parent).free
    existing = target.size if target.exists and target.size is not None else 0
    required = max(0, source.size - existing)

    if required > free:
      console.print(
        "[bold red]Insufficient free space for the output file.[/]\n"
        f"Required: {human_bytes(required)}\n"
        f"Free:     {human_bytes(free)}"
      )
      raise SystemExit(2)


def confirm_target(target: Endpoint, assume_yes: bool) -> None:
  """Require explicit confirmation before destructive writes."""
  if assume_yes:
    return

  if target.block:
    console.print()
    console.print(
      "[bold red]DESTRUCTIVE WRITE[/]: all overwritten data on the target "
      "will be lost."
    )
    expected = str(target.path)
    entered = console.input(
      f"Type the exact target path [bold]{expected}[/] to continue: "
    )

    if entered != expected:
      console.print("[yellow]Confirmation did not match; aborted.[/]")
      raise SystemExit(1)

  elif target.exists:
    entered = console.input(
      f"[yellow]Output file already exists:[/] {target.path}\n"
      "Type [bold]OVERWRITE[/] to replace it: "
    )

    if entered != "OVERWRITE":
      console.print("[yellow]Confirmation did not match; aborted.[/]")
      raise SystemExit(1)


# -- dd execution ---------------------------------------------------------------

def stderr_reader(stream: BinaryIO, output: queue.Queue[str]) -> None:
  """Split dd stderr on either carriage returns or newlines."""
  buffer = bytearray()

  while True:
    chunk = stream.read(1)

    if not chunk:
      break

    if chunk in (b"\r", b"\n"):
      if buffer:
        output.put(buffer.decode("utf-8", errors="replace"))
        buffer.clear()
    else:
      buffer.extend(chunk)

  if buffer:
    output.put(buffer.decode("utf-8", errors="replace"))


def make_live_group(
  progress: Progress,
  current_rate: float,
  average_rate: float,
  elapsed: float,
  history: deque[float],
) -> Group:
  """Build the live status region."""
  stats = Table.grid(expand=True)
  stats.add_column()
  stats.add_column(justify="right")
  stats.add_row(
    f"Current  [bold]{human_bytes(current_rate)}/s[/]",
    f"Elapsed  [bold]{human_seconds(elapsed)}[/]",
  )
  stats.add_row(
    f"Average  [bold]{human_bytes(average_rate)}/s[/]",
    f"History  [cyan]{sparkline(history)}[/]",
  )

  return Group(
    progress,
    Panel(stats, title="Transfer telemetry", border_style="blue"),
  )


def run_dd(
  source: Endpoint,
  target: Endpoint,
  *,
  block_size_arg: str,
  verbose: bool,
) -> tuple[int, float, list[str]]:
  """Run GNU dd and render its progress with Rich."""
  dd = require_command("dd")
  command = [
    dd,
    f"if={source.path}",
    f"of={target.path}",
    f"bs={block_size_arg}",
    "status=progress",
    "conv=fsync",
  ]

  if verbose:
    console.print("\n[bold]Command[/]")
    console.print(f"[dim]{shlex.join(command)}[/]\n")

  env = os.environ.copy()
  env["LC_ALL"] = "C"

  process = subprocess.Popen(
    command,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.PIPE,
    env=env,
  )

  if process.stderr is None:
    raise RuntimeError("Could not capture dd stderr.")

  lines: queue.Queue[str] = queue.Queue()
  thread = threading.Thread(
    target=stderr_reader,
    args=(process.stderr, lines),
    daemon=True,
  )
  thread.start()

  progress = Progress(
    SpinnerColumn(),
    TextColumn("[bold cyan]{task.description}"),
    BarColumn(bar_width=None),
    TaskProgressColumn(),
    DownloadColumn(),
    TransferSpeedColumn(),
    TimeRemainingColumn(),
    expand=True,
    auto_refresh=False,
  )
  task = progress.add_task("Writing", total=source.size)

  start = time.monotonic()
  last_sample_time = start
  last_sample_bytes = 0
  completed = 0
  current_rate = 0.0
  history: deque[float] = deque(maxlen=30)
  diagnostics: list[str] = []

  with Live(
    make_live_group(progress, 0.0, 0.0, 0.0, history),
    console=console,
    refresh_per_second=8,
  ) as live:
    while process.poll() is None or not lines.empty():
      saw_progress = False

      try:
        while True:
          line = lines.get_nowait()
          match = DD_PROGRESS_RE.match(line)

          if match:
            completed = int(match.group(1))
            saw_progress = True
          elif line.strip():
            diagnostics.append(line.strip())
      except queue.Empty:
        pass

      now = time.monotonic()

      if saw_progress or now - last_sample_time >= 0.5:
        delta_time = max(now - last_sample_time, 1e-9)
        delta_bytes = max(completed - last_sample_bytes, 0)
        current_rate = delta_bytes / delta_time

        if delta_bytes > 0:
          history.append(current_rate)

        elapsed = max(now - start, 1e-9)
        average_rate = completed / elapsed
        progress.update(task, completed=completed)
        live.update(
          make_live_group(
            progress,
            current_rate,
            average_rate,
            elapsed,
            history,
          )
        )
        last_sample_time = now
        last_sample_bytes = completed

      time.sleep(0.05)

    thread.join(timeout=1.0)

    try:
      while True:
        line = lines.get_nowait()
        match = DD_PROGRESS_RE.match(line)
        if match:
          completed = int(match.group(1))
        elif line.strip():
          diagnostics.append(line.strip())
    except queue.Empty:
      pass

    elapsed = max(time.monotonic() - start, 1e-9)
    progress.update(task, completed=completed)
    live.update(
      make_live_group(
        progress,
        0.0,
        completed / elapsed,
        elapsed,
        history,
      )
    )

  return process.returncode, elapsed, diagnostics


# -- Verification ---------------------------------------------------------------

def hash_prefix(
  path: Path,
  size: int,
  progress: Progress,
  task_id: int,
) -> str:
  """Calculate SHA-256 over exactly `size` bytes."""
  digest = hashlib.sha256()
  remaining = size

  with path.open("rb", buffering=0) as handle:
    while remaining:
      chunk = handle.read(min(8 * 1024 * 1024, remaining))

      if not chunk:
        raise OSError(
          f"Unexpected EOF while verifying {path}; "
          f"{human_bytes(remaining)} remained."
        )

      digest.update(chunk)
      remaining -= len(chunk)
      progress.advance(task_id, len(chunk))

  return digest.hexdigest()


def verify_sha256(source: Endpoint, target: Endpoint) -> tuple[str, str, float]:
  """Hash the written byte range on source and target."""
  if source.size is None:
    raise RuntimeError("Cannot verify a source with unknown size.")

  total = source.size * 2
  progress = Progress(
    SpinnerColumn(),
    TextColumn("[bold cyan]{task.description}"),
    BarColumn(bar_width=None),
    TaskProgressColumn(),
    DownloadColumn(),
    TransferSpeedColumn(),
    TimeRemainingColumn(),
    expand=True,
  )
  task = progress.add_task("SHA-256 verification", total=total)

  started = time.monotonic()

  with progress:
    source_hash = hash_prefix(source.path, source.size, progress, task)
    target_hash = hash_prefix(target.path, source.size, progress, task)

  return source_hash, target_hash, time.monotonic() - started


# -- Reporting -----------------------------------------------------------------

def print_summary(
  source: Endpoint,
  target: Endpoint,
  elapsed: float,
  verified: bool | None,
  verification_time: float | None,
) -> None:
  """Print the final transfer summary."""
  table = Table(title="Transfer complete", show_header=False)
  table.add_column("Field", style="bold")
  table.add_column("Value")

  table.add_row("Source", str(source.path))
  table.add_row("Target", str(target.path))
  table.add_row("Bytes", human_bytes(source.size))
  table.add_row("Copy time", human_seconds(elapsed))

  if source.size is not None and elapsed > 0:
    table.add_row("Average", f"{human_bytes(source.size / elapsed)}/s")

  if verified is not None:
    table.add_row(
      "SHA-256",
      "[green]MATCH[/]" if verified else "[bold red]MISMATCH[/]",
    )

  if verification_time is not None:
    table.add_row("Verify time", human_seconds(verification_time))

  console.print()
  console.print(table)


# -- CLI -----------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
  """Create the command-line parser."""
  parser = argparse.ArgumentParser(
    prog=APP,
    description=(
      "A safer, richer front end for GNU dd with live progress and optional "
      "SHA-256 verification."
    ),
    formatter_class=argparse.RawDescriptionHelpFormatter,
    epilog="""Examples:
  rdd --list
  rdd archlinux.iso /dev/sdb
  rdd disk.img backup.img --verify
  sudo rdd image.iso /dev/sdc --bs 8M --verify
  rdd source.img target.img --dry-run --verbose

Safety:
  * Mounted block-device targets are always refused.
  * Block-device writes require root.
  * Destructive targets require an exact typed confirmation unless --yes is
    supplied.
  * --yes is intended for scripts where the target has already been validated.
""",
  )

  parser.add_argument("source", nargs="?", help="input file or block device")
  parser.add_argument("target", nargs="?", help="output file or block device")
  parser.add_argument(
    "--bs",
    default="4M",
    metavar="SIZE",
    help="GNU dd block size (default: 4M)",
  )
  parser.add_argument(
    "--verify",
    action="store_true",
    help="verify the copied byte range with SHA-256 after writing",
  )
  parser.add_argument(
    "--dry-run",
    action="store_true",
    help="inspect and validate without writing anything",
  )
  parser.add_argument(
    "-y",
    "--yes",
    action="store_true",
    help="skip the interactive destructive-write confirmation",
  )
  parser.add_argument(
    "-v",
    "--verbose",
    action="store_true",
    help="show the underlying dd command and final dd diagnostics",
  )
  parser.add_argument(
    "--list",
    action="store_true",
    help="list top-level block devices and exit",
  )
  parser.add_argument(
    "--version",
    action="version",
    version=f"%(prog)s {VERSION}",
  )

  return parser


def main() -> int:
  """CLI entry point."""
  parser = build_parser()
  args = parser.parse_args()

  if args.list:
    list_devices()
    return 0

  if not args.source or not args.target:
    parser.error("SOURCE and TARGET are required unless --list is used")

  source = resolve_endpoint(args.source, source=True)
  target = resolve_endpoint(args.target, source=False)

  console.print()
  console.print(endpoint_panel("Source", source))
  console.print(endpoint_panel("Target", target))

  validate_transfer(source, target)

  if args.dry_run:
    console.print("\n[green]Dry run passed.[/] No data was written.")
    return 0

  confirm_target(target, args.yes)

  returncode, elapsed, diagnostics = run_dd(
    source,
    target,
    block_size_arg=args.bs,
    verbose=args.verbose,
  )

  if args.verbose and diagnostics:
    table = Table(title="dd diagnostics")
    table.add_column("stderr")
    for line in diagnostics:
      table.add_row(line)
    console.print(table)

  if returncode != 0:
    console.print(
      f"\n[bold red]dd failed[/] with exit status {returncode}. "
      "The target may contain a partial copy."
    )
    return returncode

  verified: bool | None = None
  verification_time: float | None = None

  if args.verify:
    console.print()
    source_hash, target_hash, verification_time = verify_sha256(source, target)
    verified = source_hash == target_hash

    if not verified:
      print_summary(
        source,
        target,
        elapsed,
        verified,
        verification_time,
      )
      console.print(
        "\n[bold red]Verification failed.[/] "
        "Do not trust the written target."
      )
      console.print(f"Source SHA-256: {source_hash}")
      console.print(f"Target SHA-256: {target_hash}")
      return 3

    if args.verbose:
      console.print(f"\n[bold]SHA-256[/] {source_hash}")

  print_summary(
    source,
    target,
    elapsed,
    verified,
    verification_time,
  )
  return 0


if __name__ == "__main__":
  try:
    raise SystemExit(main())
  except KeyboardInterrupt:
    console.print(
      "\n[yellow]Interrupted.[/] The target may contain a partial copy."
    )
    raise SystemExit(130)
