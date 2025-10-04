#!/usr/bin/env python3
"""
lvm_check_space — LVM logical volume usage in a Rich-styled table.

What it does
  • Reads LV metadata via `lvs --reportformat json` (no sudo needed on typical Arch).
  • Resolves mount points via `lsblk -J -o NAME,PATH,MOUNTPOINT`.
  • Computes USED/FREE/%%USED with Python's shutil.disk_usage when the LV is mounted.
  • Falls back to lsblk+df if `lvs` is unavailable or restricted.
  • Matches the visual style of your device-mapper table (bold cyan header, heavy box).

Usage
  lvm_check_space [--json] [--only-mounted] [--vg VG_NAME] [--sort {used,free,percent,size,name}]
                  [--no-color]

Options
  --json           Emit raw JSON (one record per LV).
  --only-mounted   Show only LVs that have a mountpoint.
  --vg VG_NAME     Filter to a specific Volume Group.
  --sort …         Sort rows by a key; default: name.
  --no-color       Disable Rich colors (useful for logs or plain TTYs).

Dependencies
  • lvm2 (for `lvs`) — optional but preferred
  • util-linux (for `lsblk`, `findmnt`)
  • Python package: rich  (Arch: pacman -S python-rich  |  pip: pip install rich)
"""

import argparse
import json
import os
import shutil
import subprocess
from typing import Dict, List, Optional

from rich.console import Console
from rich.table import Table
from rich import box

# ---------- Helpers -----------------------------------------------------------

def _run_json(cmd: List[str]) -> Optional[dict]:
    try:
        out = subprocess.check_output(cmd, text=True)
        return json.loads(out)
    except (subprocess.CalledProcessError, FileNotFoundError, json.JSONDecodeError):
        return None

def _format_size(nbytes: int) -> str:
    # binary units, aligned with your device-mapper script
    units = ["B", "K", "M", "G", "T", "P", "E"]
    x = float(nbytes)
    for u in units:
        if x < 1024.0:
            return f"{x:.1f}{u}"
        x /= 1024.0
    return f"{x:.1f}Z"

def _mount_map() -> Dict[str, str]:
    """PATH → MOUNTPOINT (only real mounts)."""
    lsblk = _run_json(["lsblk", "-J", "-o", "NAME,PATH,MOUNTPOINT"])
    m = {}
    def walk(nodes):
        for n in nodes:
            path = n.get("path")
            mp = n.get("mountpoint") or ""
            if path and mp and os.path.ismount(mp):
                m[path] = mp
            for ch in n.get("children", []) or []:
                walk(ch)
    if lsblk and "blockdevices" in lsblk:
        walk(lsblk["blockdevices"])
    return m

def _disk_usage_safe(mount: str):
    try:
        u = shutil.disk_usage(mount)
        used = u.used
        free = u.free
        total = u.total
        pct = (used / total * 100.0) if total else 0.0
        return used, free, total, pct
    except Exception:
        return None

def _read_lvs() -> Optional[List[dict]]:
    """Preferred source: lvs JSON."""
    j = _run_json(["lvs", "--reportformat", "json", "-o",
                   "lv_name,vg_name,lv_path,lv_size,lv_attr,data_percent"])
    if not j:
        return None
    # Arch lvm JSON shape: {"report":[{"lv":[ {...}, ... ]}]}
    try:
        return j["report"][0]["lv"]
    except Exception:
        return None

def _fallback_lvs_from_lsblk() -> List[dict]:
    """If lvs is unavailable, approximate from lsblk."""
    j = _run_json(["lsblk", "-J", "-b", "-o", "NAME,TYPE,PATH,SIZE"])
    rows = []
    def walk(nodes):
        for n in nodes:
            if n.get("type") == "lvm":
                rows.append({
                    "lv_name": n.get("name", ""),
                    "vg_name": "",  # unknown without lvs
                    "lv_path": n.get("path", ""),
                    "lv_size": n.get("size", "0"),
                    "lv_attr": "",
                    "data_percent": ""
                })
            for ch in n.get("children", []) or []:
                walk(ch)
    if j and "blockdevices" in j:
        walk(j["blockdevices"])
    return rows

# ---------- Core --------------------------------------------------------------

def gather(args) -> List[dict]:
    lvs = _read_lvs()
    if lvs is None:
        lvs = _fallback_lvs_from_lsblk()

    mounts = _mount_map()
    out = []
    for row in lvs:
        lv = {
            "lv_name": row.get("lv_name", ""),
            "vg_name": row.get("vg_name", ""),
            "lv_path": row.get("lv_path", ""),
            "lv_attr": row.get("lv_attr", ""),
        }
        # size in bytes; lvs may emit like "123456B" or plain bytes depending on version
        raw_size = str(row.get("lv_size", "0")).rstrip("B")
        try:
            lv_size_b = int(raw_size)
        except ValueError:
            # final fallback if lvs emitted units unexpectedly
            lv_size_b = 0
        lv["size_bytes"] = lv_size_b

        mount = mounts.get(lv["lv_path"], "")
        lv["mountpoint"] = mount

        # Only compute usage for real mounts
        used_b = free_b = total_b = 0
        pct = None
        if mount and os.path.ismount(mount):
            du = _disk_usage_safe(mount)
            if du:
                used_b, free_b, total_b, pct = du
        lv["used_bytes"] = used_b
        lv["free_bytes"] = free_b
        lv["percent_used"] = pct  # may be None if unmounted

        out.append(lv)

    # filters
    if args.vg:
        out = [x for x in out if x.get("vg_name") == args.vg]
    if args.only_mounted:
        out = [x for x in out if x.get("mountpoint")]

    # sorting
    key = args.sort
    def kf(x):
        if key == "used":
            return x.get("used_bytes", 0)
        if key == "free":
            return x.get("free_bytes", 0)
        if key == "percent":
            return (x.get("percent_used") if x.get("percent_used") is not None else -1.0)
        if key == "size":
            return x.get("size_bytes", 0)
        return (x.get("vg_name",""), x.get("lv_name",""))
    out.sort(key=kf)
    return out

def as_json(rows: List[dict]) -> str:
    j = []
    for r in rows:
        j.append({
            "vg": r["vg_name"],
            "lv": r["lv_name"],
            "path": r["lv_path"],
            "mount": r["mountpoint"],
            "size_bytes": r["size_bytes"],
            "used_bytes": r["used_bytes"],
            "free_bytes": r["free_bytes"],
            "percent_used": r["percent_used"],
            "attrs": r["lv_attr"],
        })
    return json.dumps(j, indent=2)

def render_table(rows: List[dict], color: bool = True):
    console = Console(no_color=not color)
    table = Table(
        box=box.HEAVY_HEAD,
        header_style="bold cyan",
        show_lines=False
    )
    table.add_column("LV", style="dim", no_wrap=True)
    table.add_column("VG")
    table.add_column("MOUNT")
    table.add_column("SIZE", justify="right")
    table.add_column("USED", justify="right")
    table.add_column("FREE", justify="right")
    table.add_column("%USED", justify="right")
    table.add_column("ATTRS", style="italic")
    table.add_column("LV PATH", style="dim")

    for r in rows:
        size_s = _format_size(r["size_bytes"])
        used_s = _format_size(r["used_bytes"]) if r["used_bytes"] else ""
        free_s = _format_size(r["free_bytes"]) if r["free_bytes"] else ""
        if r["percent_used"] is None:
            pct_s = ""
        else:
            pct = r["percent_used"]
            # subtle severity coloring
            if pct >= 90:
                pct_s = f"[bold red]{pct:.0f}%[/]"
            elif pct >= 75:
                pct_s = f"[yellow]{pct:.0f}%[/]"
            else:
                pct_s = f"[green]{pct:.0f}%[/]"

        table.add_row(
            r["lv_name"],
            r["vg_name"],
            r["mountpoint"] or "",
            size_s,
            used_s,
            free_s,
            pct_s,
            r["lv_attr"],
            r["lv_path"]
        )

    console.print(table)

def main():
    p = argparse.ArgumentParser(description="Show LVM logical volume usage in a Rich-styled table.")
    p.add_argument("--json", action="store_true", help="Output JSON instead of a table")
    p.add_argument("--only-mounted", action="store_true", help="Show only LVs with a mountpoint")
    p.add_argument("--vg", metavar="VG_NAME", help="Filter to a specific volume group")
    p.add_argument("--sort", choices=["name","used","free","percent","size"], default="name",
                   help="Sort rows (default: name)")
    p.add_argument("--no-color", action="store_true", help="Disable color output")
    args = p.parse_args()

    rows = gather(args)
    if args.json:
        print(as_json(rows))
        return
    render_table(rows, color=not args.no_color)

if __name__ == "__main__":
    main()

