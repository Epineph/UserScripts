#!/usr/bin/env python3

import json
import subprocess
import sys
from typing import Any

from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich.tree import Tree


# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

LSBLK_COLUMNS = (
  "NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS,MODEL,TRAN,ROTA,RM,RO"
)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

def run_lsblk_json() -> dict[str, Any]:
  """
  Run lsblk and return parsed JSON.

  Raises:
    SystemExit: If lsblk fails or returns invalid JSON.
  """
  cmd = [
    "lsblk",
    "-J",
    "-o",
    LSBLK_COLUMNS,
  ]

  try:
    result = subprocess.run(
      cmd,
      check=True,
      capture_output=True,
      text=True,
    )
  except subprocess.CalledProcessError as exc:
    print(f"Error: lsblk failed with exit code {exc.returncode}.", file=sys.stderr)
    print(exc.stderr, file=sys.stderr)
    raise SystemExit(1)

  try:
    return json.loads(result.stdout)
  except json.JSONDecodeError as exc:
    print(f"Error: failed to parse lsblk JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)


def fmt_boolish(value: Any, true_text: str, false_text: str) -> str:
  """
  Convert lsblk 0/1 or bool-like values into readable text.
  """
  return true_text if str(value) in {"1", "True", "true"} else false_text


def safe_mounts(device: dict[str, Any]) -> str:
  """
  Return mountpoints as a readable string.
  """
  mounts = device.get("mountpoints")
  if isinstance(mounts, list):
    mounts = [m for m in mounts if m]
    return ", ".join(mounts) if mounts else "-"
  mount = device.get("mountpoint")
  return mount if mount else "-"


def style_for_type(devtype: str) -> str:
  """
  Map lsblk TYPE to a Rich style.
  """
  return {
    "disk": "bold cyan",
    "part": "green",
    "crypt": "bold magenta",
    "lvm": "yellow",
    "raid": "bold red",
    "rom": "white",
    "loop": "blue",
  }.get(devtype, "default")


def make_label(device: dict[str, Any]) -> str:
  """
  Create a compact Rich label for a device in the tree.
  """
  name = device.get("name", "?")
  devtype = device.get("type", "?")
  size = device.get("size", "?")
  fstype = device.get("fstype") or "-"
  mounts = safe_mounts(device)

  style = style_for_type(devtype)

  parts = [
    f"[{style}]{name}[/{style}]",
    f"({devtype}, {size})",
  ]

  if fstype != "-":
    parts.append(f"[bright_black]fs={fstype}[/bright_black]")

  if mounts != "-":
    parts.append(f"[bold white]mounted:[/bold white] {mounts}")

  return " ".join(parts)


def add_children(node: Tree, device: dict[str, Any]) -> None:
  """
  Recursively add children devices to a Rich tree.
  """
  child_node = node.add(make_label(device))

  for child in device.get("children", []) or []:
    add_children(child_node, child)


def build_tree(data: dict[str, Any]) -> Tree:
  """
  Build a Rich tree from lsblk JSON data.
  """
  root = Tree("[bold underline]Block devices[/bold underline]")

  for device in data.get("blockdevices", []):
    add_children(root, device)

  return root


def build_summary_table(data: dict[str, Any]) -> Table:
  """
  Build a compact summary table for top-level block devices.
  """
  table = Table(title="Top-level devices", expand=True)

  table.add_column("Name", style="bold")
  table.add_column("Type")
  table.add_column("Size", justify="right")
  table.add_column("Transport")
  table.add_column("Rotational")
  table.add_column("Removable")
  table.add_column("Read-only")
  table.add_column("Model")
  table.add_column("Mounted")

  for device in data.get("blockdevices", []):
    table.add_row(
      str(device.get("name", "-")),
      str(device.get("type", "-")),
      str(device.get("size", "-")),
      str(device.get("tran") or "-"),
      fmt_boolish(device.get("rota"), "yes", "no"),
      fmt_boolish(device.get("rm"), "yes", "no"),
      fmt_boolish(device.get("ro"), "yes", "no"),
      str(device.get("model") or "-"),
      safe_mounts(device),
    )

  return table


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

def main() -> None:
  """
  Entry point.
  """
  console = Console()
  data = run_lsblk_json()

  console.print(
    Panel.fit(
      "[bold]lsblk[/bold] rendered from structured JSON with [bold]Rich[/bold]",
      border_style="cyan",
    )
  )
  console.print(build_summary_table(data))
  console.print()
  console.print(build_tree(data))


if __name__ == "__main__":
  main()
