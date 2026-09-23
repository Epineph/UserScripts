#!/usr/bin/env python3
"""RDD: a Rich front end for GNU dd and related block-device operations.

Commands
--------
copy
  Copy a file or block device using GNU dd, with progress and optional
  SHA-256 verification.

wipe
  Overwrite exactly the logical size of a block device with zeros or random
  bytes. GNU dd remains the actual write engine.

discard
  Issue BLKDISCARD through util-linux blkdiscard. This is fast on supported
  SSD/NVMe storage, but is not synonymous with controller-level sanitisation.

verify
  Compare SHA-256 over a source-sized prefix of two endpoints, or verify that
  an entire target reads back as zeros.

inspect
  Show block-device metadata, mounted descendants, and active swap use.

Linux only. Requires Python 3, Rich, GNU coreutils, and util-linux.
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
except ImportError:
  print(
    "rdd requires the Python package 'rich'.\n"
    "Install it with your package manager or: python -m pip install rich",
    file=sys.stderr,
  )
  raise SystemExit(2)


APP = "rdd"
VERSION = "0.3.0"
SPARK_CHARS = "▁▂▃▄▅▆▇█"
DD_PROGRESS_RE = re.compile(r"^\s*(\d+)\s+bytes\b")
COMMANDS = {"copy", "wipe", "discard", "verify", "inspect"}
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
  """Return a compact Unicode throughput history graph."""
  if not values:
    return "·"

  maximum = max(values)

  if maximum <= 0:
    return SPARK_CHARS[0] * len(values)

  output: list[str] = []
  last = len(SPARK_CHARS) - 1

  for value in values:
    index = min(last, int((value / maximum) * last))
    output.append(SPARK_CHARS[index])

  return "".join(output)


# -- External commands ----------------------------------------------------------

def configure_io_priority(args: argparse.Namespace) -> None:
  """Apply best-effort ionice priority to this process and its children."""
  if getattr(args, "no_ionice", False):
    return

  if args.command == "inspect":
    return

  priority = getattr(args, "ionice_priority", 0)
  ionice = shutil.which("ionice")

  if ionice is None:
    console.print(
      "[yellow]Warning:[/] ionice was not found; continuing with the "
      "kernel's default I/O priority."
    )
    return

  command = [
    ionice,
    "-c",
    "2",
    "-n",
    str(priority),
    "-p",
    str(os.getpid()),
  ]
  result = subprocess.run(
    command,
    capture_output=True,
    text=True,
  )

  if result.returncode != 0:
    message = result.stderr.strip() or result.stdout.strip()
    console.print(
      "[yellow]Warning:[/] could not apply ionice priority; continuing "
      "without changing I/O scheduling."
    )
    if message and getattr(args, "verbose", False):
      console.print(f"[dim]{message}[/]")
    return

  if getattr(args, "verbose", False):
    console.print(
      f"[dim]I/O scheduling: best-effort class, priority {priority} "
      f"(PID {os.getpid()})[/]"
    )


def require_command(name: str) -> str:
  """Return an executable path or exit with a useful error."""
  resolved = shutil.which(name)

  if resolved is None:
    console.print(f"[bold red]Missing required command:[/] {name}")
    raise SystemExit(2)

  return resolved


def run_capture(command: list[str]) -> subprocess.CompletedProcess[str]:
  """Run a command and return captured text output."""
  try:
    return subprocess.run(
      command,
      check=True,
      capture_output=True,
      text=True,
    )
  except subprocess.CalledProcessError as exc:
    message = exc.stderr.strip() or exc.stdout.strip() or str(exc)
    console.print(f"[bold red]Command failed:[/] {shlex.join(command)}")
    console.print(message)
    raise SystemExit(exc.returncode or 2) from exc


# -- System inspection ----------------------------------------------------------

def is_block_device(path: Path) -> bool:
  """Return True when path exists and is a block device."""
  try:
    return stat.S_ISBLK(path.stat().st_mode)
  except FileNotFoundError:
    return False


def block_size(path: Path) -> int:
  """Read the exact logical capacity of a block device."""
  blockdev = require_command("blockdev")
  result = run_capture([blockdev, "--getsize64", str(path)])
  return int(result.stdout.strip())


def read_active_swaps() -> set[str]:
  """Return canonical paths currently active as swap."""
  swaps: set[str] = set()

  try:
    lines = Path("/proc/swaps").read_text(encoding="utf-8").splitlines()
  except OSError:
    return swaps

  for line in lines[1:]:
    fields = line.split()

    if not fields:
      continue

    raw = fields[0]

    try:
      swaps.add(str(Path(raw).resolve()))
    except OSError:
      swaps.add(raw)

  return swaps


def lsblk_json(path: Path | None = None, *, top_only: bool = False) -> dict:
  """Return selected lsblk data as JSON."""
  lsblk = require_command("lsblk")
  command = [
    lsblk,
    "--json",
    "--bytes",
    "--output",
    (
      "NAME,PATH,TYPE,SIZE,MODEL,SERIAL,TRAN,RO,RM,PKNAME,"
      "FSTYPE,FSVER,LABEL,UUID,MOUNTPOINTS"
    ),
  ]

  if top_only:
    command.append("--nodeps")

  if path is not None:
    command.append(str(path))

  result = run_capture(command)
  return json.loads(result.stdout)


def flatten_nodes(nodes: list[dict]) -> list[dict]:
  """Flatten an lsblk tree."""
  output: list[dict] = []

  for node in nodes:
    output.append(node)
    output.extend(flatten_nodes(node.get("children", [])))

  return output


def inspect_block(path: Path) -> dict:
  """Return metadata and descendant-use information for a block device."""
  data = lsblk_json(path)
  devices = data.get("blockdevices", [])

  if not devices:
    return {}

  root = devices[0]
  nodes = flatten_nodes(devices)
  mounts: list[str] = []
  paths: list[str] = []
  active_swaps = read_active_swaps()
  swaps: list[str] = []

  for node in nodes:
    node_path = node.get("path")

    if node_path:
      try:
        canonical = str(Path(node_path).resolve())
      except OSError:
        canonical = str(node_path)

      paths.append(str(node_path))

      if canonical in active_swaps:
        swaps.append(str(node_path))

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
    "parent": root.get("pkname") or "",
    "fstype": root.get("fstype") or "",
    "fsver": root.get("fsver") or "",
    "label": root.get("label") or "",
    "uuid": root.get("uuid") or "",
    "read_only": bool(root.get("ro")),
    "removable": bool(root.get("rm")),
    "mounts": sorted(set(mounts)),
    "swaps": sorted(set(swaps)),
    "node_paths": sorted(set(paths)),
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
  """Create a compact endpoint-information panel."""
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
    table.add_row("Filesystem", meta.get("fstype") or "—")
    table.add_row("Label", meta.get("label") or "—")
    table.add_row("Removable", "yes" if meta.get("removable") else "no")

    mounts = ", ".join(meta.get("mounts", [])) or "none"
    swaps = ", ".join(meta.get("swaps", [])) or "none"

    table.add_row("Mounted", mounts)
    table.add_row("Active swap", swaps)

  return Panel(table, title=title, border_style="cyan")


def erase_plan_panel(target: Endpoint, method: str) -> Panel:
  """Create a detailed erasure-plan panel."""
  table = Table.grid(padding=(0, 2))
  table.add_column(style="bold")
  table.add_column()

  table.add_row("Target", str(target.path))
  table.add_row("Capacity", human_bytes(target.size))
  table.add_row("Method", method)
  table.add_row("Mounted", "none")
  table.add_row("Active swap", "none")
  table.add_row("Write length", "exact logical device size")

  return Panel(
    table,
    title="Destructive operation",
    border_style="red",
  )


def list_devices() -> None:
  """Print a readable top-level block-device inventory."""
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

def require_root_for_block_write(target: Endpoint) -> None:
  """Require root before writing directly to a block device."""
  if target.block and os.geteuid() != 0:
    console.print(
      "[bold red]Writing to a block device requires root.[/]\n"
      "Run the same command through sudo."
    )
    raise SystemExit(2)


def validate_block_target(target: Endpoint) -> None:
  """Reject mounted, active-swap, or read-only block-device targets."""
  if not target.block:
    console.print(
      f"[bold red]A block device is required:[/] {target.path}"
    )
    raise SystemExit(2)

  meta = target.metadata

  if meta.get("read_only"):
    console.print("[bold red]Target block device is read-only.[/]")
    raise SystemExit(2)

  mounts = meta.get("mounts", [])

  if mounts:
    console.print(
      "[bold red]Refusing to modify a mounted block device.[/]\n"
      f"Mounted filesystems: {', '.join(mounts)}"
    )
    raise SystemExit(2)

  swaps = meta.get("swaps", [])

  if swaps:
    console.print(
      "[bold red]Refusing to modify an active swap device.[/]\n"
      f"Active swap: {', '.join(swaps)}"
    )
    raise SystemExit(2)

  require_root_for_block_write(target)


def validate_transfer(source: Endpoint, target: Endpoint) -> None:
  """Reject unsafe or impossible copy operations."""
  try:
    source_resolved = source.path.resolve()
    target_resolved = target.path.resolve()
  except OSError:
    source_resolved = source.path
    target_resolved = target.path

  if source_resolved == target_resolved:
    console.print("[bold red]Source and target resolve to the same path.[/]")
    raise SystemExit(2)

  if target.block:
    validate_block_target(target)

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


def confirm_target(
  target: Endpoint,
  assume_yes: bool,
  *,
  action: str,
) -> None:
  """Require exact confirmation before a destructive operation."""
  if assume_yes:
    return

  if target.block:
    console.print()
    console.print(
      f"[bold red]{action.upper()}[/]: data on the selected target can be "
      "irreversibly destroyed."
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


# -- Live dd execution ----------------------------------------------------------

def stderr_reader(stream: BinaryIO, output: queue.Queue[str]) -> None:
  """Split dd stderr on carriage returns or newlines."""
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
  *,
  detail: str | None = None,
) -> Group:
  """Build the live transfer status region."""
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

  if detail:
    stats.add_row(detail, "")

  return Group(
    progress,
    Panel(stats, title="I/O telemetry", border_style="blue"),
  )


def run_dd_command(
  command: list[str],
  *,
  total: int | None,
  description: str,
  verbose: bool,
  detail: str | None = None,
) -> tuple[int, float, int, list[str]]:
  """Run GNU dd and render status=progress output using Rich."""
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
  task = progress.add_task(description, total=total)

  start = time.monotonic()
  last_sample_time = start
  last_sample_bytes = 0
  completed = 0
  history: deque[float] = deque(maxlen=30)
  diagnostics: list[str] = []

  with Live(
    make_live_group(
      progress,
      0.0,
      0.0,
      0.0,
      history,
      detail=detail,
    ),
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
            detail=detail,
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
        detail=detail,
      )
    )

  return process.returncode, elapsed, completed, diagnostics


def print_diagnostics(title: str, diagnostics: list[str]) -> None:
  """Print captured stderr diagnostics."""
  if not diagnostics:
    return

  table = Table(title=title)
  table.add_column("stderr")

  for line in diagnostics:
    table.add_row(line)

  console.print(table)


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


def verify_sha256(
  source: Endpoint,
  target: Endpoint,
) -> tuple[str, str, float]:
  """Hash the source and the equal-length prefix of the target."""
  if source.size is None:
    raise RuntimeError("Cannot verify a source with unknown size.")

  if target.size is not None and target.size < source.size:
    console.print("[bold red]Target is shorter than the source.[/]")
    raise SystemExit(2)

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


def verify_zeroes(target: Endpoint) -> tuple[bool, int | None, float]:
  """Read the entire target and check that every byte is zero."""
  if target.size is None:
    raise RuntimeError("Cannot verify a target with unknown size.")

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
  task = progress.add_task("Zero verification", total=target.size)
  offset = 0
  started = time.monotonic()
  bad_offset: int | None = None

  with progress:
    with target.path.open("rb", buffering=0) as handle:
      while offset < target.size:
        size = min(8 * 1024 * 1024, target.size - offset)
        chunk = handle.read(size)

        if not chunk:
          raise OSError(
            f"Unexpected EOF while verifying {target.path}."
          )

        if chunk != bytes(len(chunk)):
          for index, value in enumerate(chunk):
            if value != 0:
              bad_offset = offset + index
              break
          break

        offset += len(chunk)
        progress.advance(task, len(chunk))

  return bad_offset is None, bad_offset, time.monotonic() - started


# -- Reporting -----------------------------------------------------------------

def print_operation_summary(
  *,
  title: str,
  target: Endpoint,
  elapsed: float,
  bytes_done: int | None,
  method: str | None = None,
  verified: bool | None = None,
  verification_time: float | None = None,
) -> None:
  """Print a generic copy/wipe/discard summary."""
  table = Table(title=title, show_header=False)
  table.add_column("Field", style="bold")
  table.add_column("Value")

  table.add_row("Target", str(target.path))

  if method:
    table.add_row("Method", method)

  if bytes_done is not None:
    table.add_row("Bytes", human_bytes(bytes_done))

  table.add_row("Elapsed", human_seconds(elapsed))

  if bytes_done is not None and elapsed > 0:
    table.add_row("Average", f"{human_bytes(bytes_done / elapsed)}/s")

  if verified is not None:
    table.add_row(
      "Verification",
      "[green]PASS[/]" if verified else "[bold red]FAIL[/]",
    )

  if verification_time is not None:
    table.add_row("Verify time", human_seconds(verification_time))

  console.print()
  console.print(table)


# -- Command handlers -----------------------------------------------------------

def command_copy(args: argparse.Namespace) -> int:
  """Implement `rdd copy`."""
  source = resolve_endpoint(args.source, source=True)
  target = resolve_endpoint(args.target, source=False)

  console.print()
  console.print(endpoint_panel("Source", source))
  console.print(endpoint_panel("Target", target))

  validate_transfer(source, target)

  if args.dry_run:
    console.print("\n[green]Dry run passed.[/] No data was written.")
    return 0

  confirm_target(target, args.yes, action="destructive write")

  dd = require_command("dd")
  command = [
    dd,
    f"if={source.path}",
    f"of={target.path}",
    f"bs={args.bs}",
    "status=progress",
    "conv=fsync",
  ]

  returncode, elapsed, completed, diagnostics = run_dd_command(
    command,
    total=source.size,
    description="Copying",
    verbose=args.verbose,
    detail=f"{source.path} → {target.path}",
  )

  if args.verbose:
    print_diagnostics("dd diagnostics", diagnostics)

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
    source_hash, target_hash, verification_time = verify_sha256(
      source,
      target,
    )
    verified = source_hash == target_hash

    if args.verbose:
      console.print(f"\n[bold]Source SHA-256[/] {source_hash}")
      console.print(f"[bold]Target SHA-256[/] {target_hash}")

  print_operation_summary(
    title="Copy complete",
    target=target,
    elapsed=elapsed,
    bytes_done=completed or source.size,
    verified=verified,
    verification_time=verification_time,
  )

  return 0 if verified is not False else 3


def command_wipe(args: argparse.Namespace) -> int:
  """Implement exact-length zero or random overwrite."""
  target = resolve_endpoint(args.target, source=True)
  validate_block_target(target)

  if target.size is None:
    console.print("[bold red]Could not determine target capacity.[/]")
    return 2

  source_path = "/dev/zero" if args.pattern == "zero" else "/dev/urandom"
  method = (
    "zero overwrite"
    if args.pattern == "zero"
    else "random-byte overwrite"
  )

  console.print()
  console.print(endpoint_panel("Target", target))
  console.print(erase_plan_panel(target, method))

  if args.verify and args.pattern != "zero":
    console.print(
      "[bold red]--verify is currently defined only for zero wipes.[/]\n"
      "Random output cannot be reconstructed from /dev/urandom after writing."
    )
    return 2

  if args.dry_run:
    console.print(
      "\n[green]Dry run passed.[/] "
      f"Would overwrite exactly {human_bytes(target.size)}."
    )
    return 0

  confirm_target(target, args.yes, action=f"{args.pattern} wipe")

  dd = require_command("dd")
  command = [
    dd,
    f"if={source_path}",
    f"of={target.path}",
    f"bs={args.bs}",
    f"count={target.size}",
    "iflag=count_bytes,fullblock",
    "status=progress",
    "conv=fsync",
  ]

  returncode, elapsed, completed, diagnostics = run_dd_command(
    command,
    total=target.size,
    description=f"Wiping ({args.pattern})",
    verbose=args.verbose,
    detail=(
      f"{source_path} → {target.path} · "
      f"exactly {human_bytes(target.size)}"
    ),
  )

  if args.verbose:
    print_diagnostics("dd diagnostics", diagnostics)

  if returncode != 0:
    console.print(
      f"\n[bold red]Wipe failed[/] with exit status {returncode}. "
      "The target may be only partially overwritten."
    )
    return returncode

  verified: bool | None = None
  verification_time: float | None = None

  if args.verify:
    console.print()
    verified, bad_offset, verification_time = verify_zeroes(target)

    if not verified and bad_offset is not None:
      console.print(
        "[bold red]Zero verification failed[/] at byte offset "
        f"{bad_offset:,}."
      )

  print_operation_summary(
    title="Wipe complete",
    target=target,
    elapsed=elapsed,
    bytes_done=completed or target.size,
    method=method,
    verified=verified,
    verification_time=verification_time,
  )

  return 0 if verified is not False else 3


def command_discard(args: argparse.Namespace) -> int:
  """Implement `rdd discard` using util-linux blkdiscard."""
  target = resolve_endpoint(args.target, source=True)
  validate_block_target(target)

  method = "secure discard" if args.secure else "discard/TRIM"

  console.print()
  console.print(endpoint_panel("Target", target))
  console.print(erase_plan_panel(target, method))
  console.print(
    "\n[dim]Note: discard is a storage-command operation, not a byte-by-byte "
    "overwrite and not necessarily equivalent to NVMe sanitize.[/]"
  )

  if args.dry_run:
    console.print("\n[green]Dry run passed.[/] No discard was issued.")
    return 0

  confirm_target(target, args.yes, action=method)

  blkdiscard = require_command("blkdiscard")
  command = [blkdiscard, "--verbose"]

  if args.secure:
    command.append("--secure")

  command.append(str(target.path))

  if args.verbose:
    console.print("\n[bold]Command[/]")
    console.print(f"[dim]{shlex.join(command)}[/]\n")

  started = time.monotonic()

  with console.status(
    f"[bold cyan]Issuing {method} to {target.path}…[/]",
    spinner="dots",
  ):
    result = subprocess.run(
      command,
      capture_output=True,
      text=True,
    )

  elapsed = time.monotonic() - started

  if args.verbose:
    if result.stdout.strip():
      console.print(result.stdout.strip())
    if result.stderr.strip():
      console.print(result.stderr.strip())

  if result.returncode != 0:
    console.print(
      f"\n[bold red]{method} failed[/] with exit status "
      f"{result.returncode}."
    )
    message = result.stderr.strip() or result.stdout.strip()

    if message:
      console.print(message)

    return result.returncode

  print_operation_summary(
    title="Discard complete",
    target=target,
    elapsed=elapsed,
    bytes_done=target.size,
    method=method,
  )
  return 0


def command_verify(args: argparse.Namespace) -> int:
  """Implement standalone verification."""
  if args.zero:
    target = resolve_endpoint(args.target, source=True)

    if not target.block and not target.exists:
      console.print(f"[bold red]Target does not exist:[/] {target.path}")
      return 2

    console.print(endpoint_panel("Target", target))
    passed, bad_offset, elapsed = verify_zeroes(target)

    if passed:
      console.print("\n[bold green]PASS[/]: every checked byte is zero.")
      return 0

    console.print(
      "\n[bold red]FAIL[/]: non-zero data found at byte offset "
      f"{bad_offset:,}."
    )
    return 3

  source = resolve_endpoint(args.source, source=True)
  target = resolve_endpoint(args.target, source=True)

  console.print()
  console.print(endpoint_panel("Source", source))
  console.print(endpoint_panel("Target", target))

  source_hash, target_hash, elapsed = verify_sha256(source, target)
  passed = source_hash == target_hash

  table = Table(title="SHA-256 verification", show_header=False)
  table.add_column("Field", style="bold")
  table.add_column("Value")
  table.add_row("Source", source_hash)
  table.add_row("Target", target_hash)
  table.add_row("Elapsed", human_seconds(elapsed))
  table.add_row(
    "Result",
    "[green]MATCH[/]" if passed else "[bold red]MISMATCH[/]",
  )
  console.print(table)

  return 0 if passed else 3


def command_inspect(args: argparse.Namespace) -> int:
  """Implement device inspection."""
  if args.target is None:
    list_devices()
    return 0

  endpoint = resolve_endpoint(args.target, source=True)
  console.print()
  console.print(endpoint_panel("Inspection", endpoint))

  if endpoint.block and endpoint.metadata.get("node_paths"):
    table = Table(title="Block-device tree")
    table.add_column("Node")
    table.add_column("Relationship")

    root = str(endpoint.path)

    for node in endpoint.metadata["node_paths"]:
      relation = "selected" if node == root else "descendant"
      table.add_row(node, relation)

    console.print(table)

  return 0


# -- CLI construction -----------------------------------------------------------

def add_ionice_options(parser: argparse.ArgumentParser) -> None:
  """Add I/O-priority controls for data-moving commands."""
  parser.add_argument(
    "--ionice-priority",
    type=int,
    choices=range(8),
    default=0,
    metavar="N",
    help=(
      "best-effort ionice priority, 0=highest and 7=lowest "
      "(default: 0)"
    ),
  )
  parser.add_argument(
    "--no-ionice",
    action="store_true",
    help="do not change the process I/O scheduling priority",
  )


def add_common_write_options(parser: argparse.ArgumentParser) -> None:
  """Add options shared by destructive write commands."""
  add_ionice_options(parser)
  parser.add_argument(
    "--dry-run",
    action="store_true",
    help="inspect and validate without changing the target",
  )
  parser.add_argument(
    "-y",
    "--yes",
    action="store_true",
    help="skip exact-path interactive confirmation",
  )
  parser.add_argument(
    "-v",
    "--verbose",
    action="store_true",
    help="show the underlying command and diagnostics",
  )


def build_parser() -> argparse.ArgumentParser:
  """Create the command-line parser."""
  parser = argparse.ArgumentParser(
    prog=APP,
    description=(
      "Rich disk copy, overwrite, discard, verification, and inspection "
      "front end for Linux."
    ),
    formatter_class=argparse.RawDescriptionHelpFormatter,
    epilog="""Examples:
  rdd inspect
  rdd inspect /dev/nvme0n1p4

  rdd copy source.img target.img --verify
  sudo rdd copy archlinux.iso /dev/sdb --verify

  sudo rdd wipe /dev/nvme0n1p4
  sudo rdd wipe /dev/nvme0n1p4 --pattern random
  sudo rdd wipe /dev/nvme0n1p4 --verify
  sudo rdd wipe /dev/nvme0n1p4 --ionice-priority 0

  sudo rdd discard /dev/nvme0n1p4

  rdd verify source.img target.img
  sudo rdd verify --zero /dev/nvme0n1p4

Backward compatibility:
  rdd SOURCE TARGET [copy options]

  The legacy two-positional form is interpreted as `rdd copy SOURCE TARGET`.

Safety:
  * Mounted targets and targets containing mounted descendants are refused.
  * Active swap targets and targets containing active swap are refused.
  * Direct block-device writes require root.
  * Destructive operations require exact target-path confirmation unless
    --yes is explicitly supplied.
  * `wipe` writes exactly the logical block-device size, avoiding the normal
    end-of-device ENOSPC result from an unbounded /dev/zero source.
  * I/O-heavy commands default to ionice best-effort priority 0. Use
    --no-ionice to leave kernel I/O scheduling unchanged.
""",
  )
  parser.add_argument(
    "--version",
    action="version",
    version=f"%(prog)s {VERSION}",
  )

  subparsers = parser.add_subparsers(dest="command", required=True)

  copy_parser = subparsers.add_parser(
    "copy",
    help="copy a file or block device using GNU dd",
  )
  copy_parser.add_argument("source")
  copy_parser.add_argument("target")
  copy_parser.add_argument(
    "--bs",
    default="4M",
    metavar="SIZE",
    help="GNU dd block size (default: 4M)",
  )
  copy_parser.add_argument(
    "--verify",
    action="store_true",
    help="verify source and written prefix using SHA-256",
  )
  add_common_write_options(copy_parser)
  copy_parser.set_defaults(handler=command_copy)

  wipe_parser = subparsers.add_parser(
    "wipe",
    help="overwrite exactly one block device with zeros or random bytes",
  )
  wipe_parser.add_argument("target")
  wipe_parser.add_argument(
    "--pattern",
    choices=("zero", "random"),
    default="zero",
    help="overwrite source pattern (default: zero)",
  )
  wipe_parser.add_argument(
    "--bs",
    default="16M",
    metavar="SIZE",
    help="GNU dd block size (default: 16M)",
  )
  wipe_parser.add_argument(
    "--verify",
    action="store_true",
    help="read the entire target back and verify zeros; zero pattern only",
  )
  add_common_write_options(wipe_parser)
  wipe_parser.set_defaults(handler=command_wipe)

  discard_parser = subparsers.add_parser(
    "discard",
    help="discard/TRIM an unused block device using blkdiscard",
  )
  discard_parser.add_argument("target")
  discard_parser.add_argument(
    "--secure",
    action="store_true",
    help="request secure discard if the device supports it",
  )
  add_common_write_options(discard_parser)
  discard_parser.set_defaults(handler=command_discard)

  verify_parser = subparsers.add_parser(
    "verify",
    help="compare SHA-256 or verify that a target is entirely zero",
  )
  verify_parser.add_argument("source", nargs="?")
  verify_parser.add_argument("target", nargs="?")
  verify_parser.add_argument(
    "--zero",
    action="store_true",
    help="verify that TARGET contains only zero bytes",
  )
  add_ionice_options(verify_parser)
  verify_parser.set_defaults(handler=command_verify)

  inspect_parser = subparsers.add_parser(
    "inspect",
    help="show block-device inventory or detailed endpoint information",
  )
  inspect_parser.add_argument("target", nargs="?")
  inspect_parser.set_defaults(handler=command_inspect)

  return parser


def normalize_legacy_argv(argv: list[str]) -> list[str]:
  """Map the old `rdd SOURCE TARGET` syntax to the copy subcommand."""
  if not argv:
    return argv

  first = argv[0]

  if first in COMMANDS or first in ("-h", "--help", "--version"):
    return argv

  if first == "--list":
    return ["inspect", *argv[1:]]

  if first.startswith("-"):
    return argv

  return ["copy", *argv]


def validate_parsed_args(
  parser: argparse.ArgumentParser,
  args: argparse.Namespace,
) -> None:
  """Validate argument combinations that argparse cannot express cleanly."""
  if args.command != "verify":
    return

  if args.zero:
    if args.source is None and args.target is None:
      parser.error("verify --zero requires TARGET")

    if args.target is None:
      args.target = args.source
      args.source = None
      return

    if args.source is not None:
      parser.error("verify --zero accepts only one TARGET")

  elif args.source is None or args.target is None:
    parser.error("verify requires SOURCE TARGET, or use verify --zero TARGET")


def main() -> int:
  """CLI entry point."""
  parser = build_parser()
  argv = normalize_legacy_argv(sys.argv[1:])
  args = parser.parse_args(argv)
  validate_parsed_args(parser, args)
  configure_io_priority(args)
  return int(args.handler(args))


if __name__ == "__main__":
  try:
    raise SystemExit(main())
  except KeyboardInterrupt:
    console.print(
      "\n[yellow]Interrupted.[/] A destructive operation may be incomplete."
    )
    raise SystemExit(130)
