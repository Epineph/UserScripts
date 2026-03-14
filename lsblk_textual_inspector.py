#!/usr/bin/env python3
"""
lsblk_textual_inspector.py

Interactive block-device inspector for Linux using lsblk JSON plus Textual.

Design goals
------------
- Preserve the dependency tree from lsblk (disk -> part -> crypt -> lvm).
- Show the metadata that matters during storage setup work:
  UUID, PARTUUID, FSTYPE, paths, mountpoints, transport, model, and more.
- Show filesystem usage only where it is logically available, i.e. for mounted
  filesystems. This is gathered from the mounted path, not inferred from the
  raw block device.
- Avoid scraping lsblk's terminal text. The application reads structured JSON.

Notes on usage figures
----------------------
Usage is displayed per mountpoint. That is the only safe general rule.
Summing usage across multiple mountpoints can double-count the same filesystem
(e.g. bind mounts or the same filesystem mounted more than once).

Requirements
------------
- Linux with lsblk on PATH
- Python 3.9+
- textual

Examples
--------
  python lsblk_textual_inspector.py
  python lsblk_textual_inspector.py --mounted-only
  python lsblk_textual_inspector.py --show-loops
  python lsblk_textual_inspector.py --refresh-seconds 3
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass
from typing import Any, Iterable

from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical
from textual.reactive import reactive
from textual.widgets import DataTable, Footer, Header, Static, Tree


# ---------------------------------------------------------------------------
# lsblk acquisition and normalization
# ---------------------------------------------------------------------------

LSBLK_COLUMNS = (
  "NAME,KNAME,PKNAME,PATH,SIZE,TYPE,FSTYPE,FSVER,LABEL,PARTLABEL,UUID,"
  "PARTUUID,MOUNTPOINTS,FSAVAIL,FSUSE%,MODEL,SERIAL,TRAN,ROTA,RM,RO,"
  "HOTPLUG"
)


@dataclass(slots=True)
class DeviceRecord:
  """Normalized representation of one lsblk node."""

  name: str
  kname: str
  pkname: str
  path: str
  size_bytes: int | None
  devtype: str
  fstype: str
  fsver: str
  label: str
  partlabel: str
  uuid: str
  partuuid: str
  mountpoints: list[str]
  fsavail: str
  fsuse_pct: str
  model: str
  serial: str
  tran: str
  rota: Any
  rm: Any
  ro: Any
  hotplug: Any
  children: list["DeviceRecord"]

  @classmethod
  def from_mapping(cls, data: dict[str, Any]) -> "DeviceRecord":
    mounts = data.get("mountpoints") or []
    if not isinstance(mounts, list):
      mounts = [str(mounts)] if mounts else []

    children = [
      cls.from_mapping(child)
      for child in (data.get("children") or [])
    ]

    size_raw = data.get("size")
    size_bytes: int | None
    if isinstance(size_raw, int):
      size_bytes = size_raw
    else:
      try:
        size_bytes = int(size_raw)
      except (TypeError, ValueError):
        size_bytes = None

    return cls(
      name=str(data.get("name") or "-"),
      kname=str(data.get("kname") or "-"),
      pkname=str(data.get("pkname") or "-"),
      path=str(data.get("path") or "-"),
      size_bytes=size_bytes,
      devtype=str(data.get("type") or "-"),
      fstype=str(data.get("fstype") or "-"),
      fsver=str(data.get("fsver") or "-"),
      label=str(data.get("label") or "-"),
      partlabel=str(data.get("partlabel") or "-"),
      uuid=str(data.get("uuid") or "-"),
      partuuid=str(data.get("partuuid") or "-"),
      mountpoints=[str(item) for item in mounts if item],
      fsavail=str(data.get("fsavail") or "-"),
      fsuse_pct=str(data.get("fsuse%") or "-"),
      model=str(data.get("model") or "-"),
      serial=str(data.get("serial") or "-"),
      tran=str(data.get("tran") or "-"),
      rota=data.get("rota"),
      rm=data.get("rm"),
      ro=data.get("ro"),
      hotplug=data.get("hotplug"),
      children=children,
    )


@dataclass(slots=True)
class MountUsage:
  """Per-mountpoint filesystem usage."""

  mountpoint: str
  total: int
  used: int
  free: int
  used_pct: float
  note: str = ""


def run_lsblk() -> list[DeviceRecord]:
  """Return the current lsblk tree as normalized records."""
  cmd = [
    "lsblk",
    "--json",
    "--bytes",
    "--output",
    LSBLK_COLUMNS,
  ]

  result = subprocess.run(
    cmd,
    capture_output=True,
    text=True,
    check=False,
  )

  if result.returncode != 0:
    stderr = result.stderr.strip() or "lsblk failed"
    raise RuntimeError(stderr)

  try:
    payload = json.loads(result.stdout)
  except json.JSONDecodeError as exc:
    raise RuntimeError(f"Failed to parse lsblk JSON: {exc}") from exc

  return [
    DeviceRecord.from_mapping(item)
    for item in payload.get("blockdevices", [])
  ]


# ---------------------------------------------------------------------------
# Formatting and filtering helpers
# ---------------------------------------------------------------------------


def fmt_bytes(value: int | None) -> str:
  """Render bytes in human-readable IEC units."""
  if value is None:
    return "-"

  units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
  size = float(value)
  for unit in units:
    if size < 1024.0 or unit == units[-1]:
      if unit == "B":
        return f"{int(size)} {unit}"
      return f"{size:.1f} {unit}"
    size /= 1024.0
  return "-"



def boolish(value: Any) -> str:
  """Normalize 0/1/bool-ish values for display."""
  if str(value) in {"1", "True", "true"}:
    return "yes"
  if str(value) in {"0", "False", "false"}:
    return "no"
  return "-"



def node_label(device: DeviceRecord) -> str:
  """Label used in the Textual tree widget."""
  size = fmt_bytes(device.size_bytes)
  fs = f" fs={device.fstype}" if device.fstype != "-" else ""
  mount = ""
  if device.mountpoints:
    mount = f" [{device.mountpoints[0]}]"
  return f"{device.name} ({device.devtype}, {size}){fs}{mount}"



def include_device(
  device: DeviceRecord,
  *,
  mounted_only: bool,
  show_loops: bool,
) -> bool:
  """Return True when a node should remain visible in the tree."""
  if not show_loops and device.devtype == "loop":
    return False

  if not mounted_only:
    return True

  if device.mountpoints:
    return True

  return any(
    include_device(
      child,
      mounted_only=True,
      show_loops=show_loops,
    )
    for child in device.children
  )



def iter_tree(device: DeviceRecord) -> Iterable[DeviceRecord]:
  """Yield a device and all descendants."""
  yield device
  for child in device.children:
    yield from iter_tree(child)



def collect_mountpoints(device: DeviceRecord) -> list[str]:
  """Collect unique mountpoints from a node and its descendants."""
  seen: set[str] = set()
  ordered: list[str] = []

  for node in iter_tree(device):
    for mountpoint in node.mountpoints:
      if mountpoint not in seen:
        seen.add(mountpoint)
        ordered.append(mountpoint)

  return ordered



def get_mount_usage(mountpoint: str) -> MountUsage | None:
  """Return mounted filesystem usage for a mountpoint, if accessible."""
  try:
    usage = shutil.disk_usage(mountpoint)
  except OSError:
    return None

  used_pct = 0.0
  if usage.total > 0:
    used_pct = 100.0 * usage.used / usage.total

  return MountUsage(
    mountpoint=mountpoint,
    total=usage.total,
    used=usage.used,
    free=usage.free,
    used_pct=used_pct,
  )



def summarize_devices(devices: list[DeviceRecord]) -> dict[str, int]:
  """Return simple type counts across a tree of devices."""
  counts: dict[str, int] = {
    "all": 0,
    "disk": 0,
    "part": 0,
    "crypt": 0,
    "lvm": 0,
    "mounted": 0,
  }

  def visit(node: DeviceRecord) -> None:
    counts["all"] += 1
    counts[node.devtype] = counts.get(node.devtype, 0) + 1
    if node.mountpoints:
      counts["mounted"] += 1
    for child in node.children:
      visit(child)

  for device in devices:
    visit(device)

  return counts


# ---------------------------------------------------------------------------
# Textual application
# ---------------------------------------------------------------------------


class LsblkInspector(App[None]):
  """Interactive lsblk browser for storage inspection workflows."""

  TITLE = "lsblk Inspector"
  SUB_TITLE = "Textual UI backed by lsblk JSON"

  CSS = """
  Screen {
    layout: vertical;
  }

  #body {
    height: 1fr;
  }

  #left {
    width: 40%;
    border: solid $primary;
  }

  #right {
    width: 60%;
  }

  #summary {
    height: 4;
    border: solid $primary;
    padding: 0 1;
  }

  #details_box {
    height: 2fr;
    border: solid $accent;
  }

  #usage_box {
    height: 1fr;
    border: solid $success;
  }

  #status {
    height: 3;
    border: solid $warning;
    padding: 0 1;
  }

  Tree {
    height: 1fr;
  }

  DataTable {
    height: 1fr;
  }
  """

  BINDINGS = [
    ("q", "quit", "Quit"),
    ("r", "refresh", "Refresh"),
    ("m", "toggle_mounted", "Mounted only"),
    ("l", "toggle_loops", "Loop devices"),
  ]

  mounted_only = reactive(False)
  show_loops = reactive(False)

  def __init__(
    self,
    *,
    refresh_seconds: float = 0.0,
    mounted_only: bool = False,
    show_loops: bool = False,
  ) -> None:
    super().__init__()
    self.refresh_seconds = refresh_seconds
    self.mounted_only = mounted_only
    self.show_loops = show_loops
    self._devices: list[DeviceRecord] = []
    self._visible_devices: list[DeviceRecord] = []
    self._selected: DeviceRecord | None = None

  def compose(self) -> ComposeResult:
    yield Header()
    yield Static(id="summary")
    with Horizontal(id="body"):
      with Vertical(id="left"):
        yield Tree("Block devices", id="device_tree")
      with Vertical(id="right"):
        with Vertical(id="details_box"):
          yield DataTable(id="details_table")
        with Vertical(id="usage_box"):
          yield DataTable(id="usage_table")
    yield Static("Loading lsblk data...", id="status")
    yield Footer()

  def on_mount(self) -> None:
    self._configure_tables()
    self.refresh_data()
    if self.refresh_seconds > 0:
      self.set_interval(self.refresh_seconds, self.refresh_data)

  def _configure_tables(self) -> None:
    details = self.query_one("#details_table", DataTable)
    usage = self.query_one("#usage_table", DataTable)

    details.cursor_type = "row"
    usage.cursor_type = "row"

    self._reset_details_table()
    self._reset_usage_table()

  def _reset_details_table(self) -> None:
    details = self.query_one("#details_table", DataTable)
    details.clear(columns=True)
    details.add_columns("Field", "Value")

  def _reset_usage_table(self) -> None:
    usage = self.query_one("#usage_table", DataTable)
    usage.clear(columns=True)
    usage.add_columns(
      "Mountpoint",
      "Total",
      "Used",
      "Available",
      "Use%",
      "Notes",
    )

  def action_refresh(self) -> None:
    self.refresh_data()

  def action_toggle_mounted(self) -> None:
    self.mounted_only = not self.mounted_only
    self.refresh_data()

  def action_toggle_loops(self) -> None:
    self.show_loops = not self.show_loops
    self.refresh_data()

  def refresh_data(self) -> None:
    tree = self.query_one("#device_tree", Tree)
    summary = self.query_one("#summary", Static)
    status = self.query_one("#status", Static)

    try:
      self._devices = run_lsblk()
    except Exception as exc:  # noqa: BLE001
      status.update(f"lsblk error: {exc}")
      summary.update("Failed to load lsblk data.")
      self._selected = None
      self._reset_details_table()
      self._reset_usage_table()
      return

    counts = summarize_devices(self._devices)
    self._visible_devices = []

    tree.clear()
    tree.root.set_label(
      "Block devices "
      f"(mounted_only={self.mounted_only}, show_loops={self.show_loops})"
    )
    tree.show_root = True

    def add_nodes(parent: Any, device: DeviceRecord) -> None:
      if not include_device(
        device,
        mounted_only=self.mounted_only,
        show_loops=self.show_loops,
      ):
        return

      self._visible_devices.append(device)
      node = parent.add(node_label(device), data=device)
      node.expand()
      for child in device.children:
        add_nodes(node, child)

    for device in self._devices:
      add_nodes(tree.root, device)

    tree.root.expand()

    summary.update(
      " | ".join(
        [
          f"devices={counts['all']}",
          f"disks={counts.get('disk', 0)}",
          f"parts={counts.get('part', 0)}",
          f"crypt={counts.get('crypt', 0)}",
          f"lvm={counts.get('lvm', 0)}",
          f"mounted={counts['mounted']}",
          f"visible={len(self._visible_devices)}",
          f"refresh={self.refresh_seconds or 'manual'}",
        ]
      )
    )

    if self._visible_devices:
      if self._selected is None:
        self._selected = self._visible_devices[0]
      else:
        selected_path = self._selected.path
        self._selected = next(
          (
            device
            for device in self._visible_devices
            if device.path == selected_path
          ),
          self._visible_devices[0],
        )

      self._update_details(self._selected)
      self._update_usage(self._selected)
      status.update(
        "Loaded lsblk successfully. "
        "Use arrows to navigate the tree, Enter to inspect a node."
      )
    else:
      self._selected = None
      self._reset_details_table()
      self._reset_usage_table()
      status.update("No devices matched the current filters.")

  def _update_details(self, device: DeviceRecord) -> None:
    details = self.query_one("#details_table", DataTable)
    self._reset_details_table()

    rows = [
      ("name", device.name),
      ("kname", device.kname),
      ("pkname", device.pkname),
      ("path", device.path),
      ("type", device.devtype),
      ("size", fmt_bytes(device.size_bytes)),
      ("fstype", device.fstype),
      ("fsver", device.fsver),
      ("label", device.label),
      ("partlabel", device.partlabel),
      ("uuid", device.uuid),
      ("partuuid", device.partuuid),
      ("mountpoints", ", ".join(device.mountpoints) or "-"),
      ("lsblk fsavail", device.fsavail),
      ("lsblk fsuse%", device.fsuse_pct),
      ("transport", device.tran),
      ("model", device.model),
      ("serial", device.serial),
      ("rotational", boolish(device.rota)),
      ("removable", boolish(device.rm)),
      ("read-only", boolish(device.ro)),
      ("hotplug", boolish(device.hotplug)),
      ("children", str(len(device.children))),
    ]

    for field, value in rows:
      details.add_row(field, value or "-")

  def _update_usage(self, device: DeviceRecord) -> None:
    usage = self.query_one("#usage_table", DataTable)
    self._reset_usage_table()

    mountpoints = collect_mountpoints(device)
    if not mountpoints:
      usage.add_row(
        "-",
        "-",
        "-",
        "-",
        "-",
        "No mounted filesystem under this node.",
      )
      return

    any_ok = False
    for mountpoint in mountpoints:
      item = get_mount_usage(mountpoint)
      if item is None:
        usage.add_row(
          mountpoint,
          "-",
          "-",
          "-",
          "-",
          "Usage unavailable for this mountpoint.",
        )
        continue

      any_ok = True
      usage.add_row(
        item.mountpoint,
        fmt_bytes(item.total),
        fmt_bytes(item.used),
        fmt_bytes(item.free),
        f"{item.used_pct:.1f}%",
        item.note,
      )

    if len(mountpoints) > 1 and any_ok:
      usage.add_row(
        "-",
        "-",
        "-",
        "-",
        "-",
        "Multiple mountpoints detected: totals are shown per mountpoint only.",
      )

  def on_tree_node_selected(self, event: Tree.NodeSelected) -> None:
    device = event.node.data
    if isinstance(device, DeviceRecord):
      self._selected = device
      self._update_details(device)
      self._update_usage(device)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
  """Return the CLI argument parser."""
  parser = argparse.ArgumentParser(
    prog="lsblk_textual_inspector.py",
    description=(
      "Interactive block-device inspector using lsblk JSON and Textual."
    ),
    epilog=(
      "Examples:\n"
      "  lsblk_textual_inspector.py\n"
      "  lsblk_textual_inspector.py --mounted-only\n"
      "  lsblk_textual_inspector.py --show-loops\n"
      "  lsblk_textual_inspector.py --refresh-seconds 2\n"
    ),
    formatter_class=argparse.RawDescriptionHelpFormatter,
  )

  parser.add_argument(
    "--mounted-only",
    action="store_true",
    help="Only show mounted nodes and ancestors required to reach them.",
  )
  parser.add_argument(
    "--show-loops",
    action="store_true",
    help="Include loop devices in the tree.",
  )
  parser.add_argument(
    "--refresh-seconds",
    type=float,
    default=0.0,
    metavar="N",
    help=(
      "Auto-refresh interval in seconds. Default: 0 (manual refresh only)."
    ),
  )

  return parser



def main() -> None:
  """CLI entry point."""
  args = build_parser().parse_args()

  try:
    app = LsblkInspector(
      refresh_seconds=max(0.0, float(args.refresh_seconds)),
      mounted_only=bool(args.mounted_only),
      show_loops=bool(args.show_loops),
    )
    app.run()
  except KeyboardInterrupt:
    pass
  except Exception as exc:  # noqa: BLE001
    print(f"Fatal error: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc


if __name__ == "__main__":
  main()
