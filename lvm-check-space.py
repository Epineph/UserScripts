#!/usr/bin/env python3
"""
lvm_check_space — LVM logical volume usage in a Rich-styled table.

What it does
  • Reads LV metadata via `lvs --reportformat json` (no sudo needed on many hosts).
  • Resolves mount points via `lsblk -J` (robust to schema quirks).
  • Computes USED/FREE/%USED with shutil.disk_usage for mounted LVs.
  • Falls back to lsblk-only discovery if `lvs` is unavailable or restricted.
  • Matches the visual style of your device-mapper table (bold cyan header, heavy box).

Usage
  lvm_check_space [--json] [--only-mounted] [--vg VG_NAME]
                  [--sort {name,used,free,percent,size}] [--no-color]

Examples
  lvm_check_space
  lvm_check_space --only-mounted --sort percent
  lvm_check_space --json | jq .

Dependencies
  • lvm2 (for `lvs`) — optional but preferred
  • util-linux (for `lsblk`)
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

# ───────────────────────────────────────────
# Helpers (robust JSON, traversal, parsing)
# ───────────────────────────────────────────

def _iter_nodes(nodes):
    """Yield dict nodes whether input is a list, a dict, or junk (skip non-dicts)."""
    if nodes is None:
        return
    if isinstance(nodes, dict):
        nodes = [nodes]
    try:
        iterator = iter(nodes)
    except TypeError:
        return
    for n in iterator:
        if isinstance(n, dict):
            yield n

def _run_json(cmd: List[str]) -> Optional[dict]:
    """Run a command expected to output JSON; harden locale and silence stderr."""
    try:
        env = os.environ.copy()
        env.setdefault("LC_ALL", "C")  # avoid localized headers/decimals
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL, env=env)
        return json.loads(out)
    except (subprocess.CalledProcessError, FileNotFoundError, json.JSONDecodeError):
        return None

def _format_size(nbytes: int) -> str:
    """Format bytes with binary units."""
    units = ["B", "K", "M", "G", "T", "P", "E", "Z", "Y"]
    x = float(nbytes)
    for u in units:
        if x < 1024.0:
            return f"{x:.1f}{u}"
        x /= 1024.0
    return f"{x:.1f}Y"

def _parse_bytes(val) -> int:
    """Parse size strings like '4.00g', '141.3G', '106954752B', or raw ints."""
    if val is None:
        return 0
    s = str(val).strip().lower()
    # Fast path: plain integer bytes
    try:
        return int(s)
    except ValueError:
        pass
    import re
    m = re.match(r'^([0-9]*\.?[0-9]+)\s*([kmgtpezy]?)b?$', s)
    if not m:
        return 0
    num = float(m.group(1))
    unit = m.group(2)
    mult = {
        '': 1, 'k': 1024**1, 'm': 1024**2, 'g': 1024**3,
        't': 1024**4, 'p': 1024**5, 'e': 1024**6, 'z': 1024**7, 'y': 1024**8
    }.get(unit, 1)
    return int(num * mult)

def _aliases_for_dev(path: str):
    """
    Yield common alias paths for an LV:
      • mapper-style: /dev/mapper/vg-lv
      • udev-style:   /dev/vg/lv
      • realpath() and the original path
    """
    paths = {path}
    rp = os.path.realpath(path)
    paths.add(rp)
    base = os.path.basename(rp)
    # /dev/mapper/vg-lv  ↔  /dev/vg/lv
    if "/mapper/" in rp and "-" in base:
        vg, lv = base.split("-", 1)
        paths.add(f"/dev/{vg}/{lv}")
    # /dev/vg/lv  ↔  /dev/mapper/vg-lv
    parts = rp.split("/")
    if len(parts) >= 4 and parts[1] == "dev":
        vg = parts[2]
        lv = parts[3] if len(parts) >= 4 else ""
        if vg and lv:
            paths.add(f"/dev/mapper/{vg}-{lv}")
    return paths

def _mount_map() -> Dict[str, str]:
    """PATH → MOUNTPOINT (only real mounts). Robust to lsblk JSON quirks."""
    lsblk = _run_json(["lsblk", "-J", "-o", "NAME,PATH,MOUNTPOINT,CHILDREN"])
    m: Dict[str, str] = {}

    def walk(nodes):
        for n in _iter_nodes(nodes):
            path = n.get("path") or n.get("name")
            mp = (n.get("mountpoint") or "").strip()
            if path and mp and os.path.ismount(mp):
                # Record all aliases so later lookups succeed regardless of form.
                for alias in _aliases_for_dev(path):
                    m[alias] = mp
            ch = n.get("children")
            if ch:
                walk(ch)

    if lsblk:
        walk(lsblk.get("blockdevices"))
    return m

def _disk_usage_safe(mount: str):
    """Return (used, free, total, percent) for a mountpoint; None on error."""
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
    """Preferred source: lvs JSON; returns list of LV dicts or None if unavailable."""
    j = _run_json([
        "lvs", "--reportformat", "json",
        "-o", "lv_name,vg_name,lv_path,lv_size,lv_attr,data_percent"
    ])
    if not j:
        return None
    try:
        return j["report"][0]["lv"]
    except Exception:
        return None

def _fallback_lvs_from_lsblk() -> List[dict]:
    """
    Approximate LVs from lsblk when lvs is unavailable/restricted.
    Identify LVs via type='lvm'/'dm', mapper paths, or udev /dev/<vg>/<lv> forms.
    """
    j = _run_json(["lsblk", "-J", "-b", "-o", "NAME,TYPE,PATH,SIZE,CHILDREN"])
    rows: List[dict] = []

    def walk(nodes):
        for n in _iter_nodes(nodes):
            typ  = (n.get("type") or "").lower()
            path = n.get("path") or n.get("name") or ""
            size_raw = n.get("size")
            try:
                size_b = int(size_raw) if size_raw not in (None, "") else 0
            except (TypeError, ValueError):
                size_b = 0

            is_lv = (
                typ in ("lvm", "dm") or
                path.startswith("/dev/mapper/") or
                (path.startswith("/dev/") and "-" in os.path.basename(os.path.realpath(path)))
            )

            if is_lv:
                # Derive best-effort VG/LV from name when possible
                base = os.path.basename(os.path.realpath(path))
                if "-" in base:
                    vg_name, lv_name = base.split("-", 1)
                else:
                    vg_name, lv_name = "", base

                rows.append({
                    "lv_name": lv_name,
                    "vg_name": vg_name,
                    "lv_path": path,
                    "lv_size": str(size_b),
                    "lv_attr": "",
                    "data_percent": ""
                })

            ch = n.get("children")
            if ch:
                walk(ch)

    if j:
        walk(j.get("blockdevices"))
    return rows

# ───────────────────────────────────────────
# Core
# ───────────────────────────────────────────

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

        # Robust size parsing (handles "4.00g", "141.3G", "106954752B", or bytes)
        lv["size_bytes"] = _parse_bytes(row.get("lv_size"))

        # Resolve mountpoint using aliases (/dev/mapper/vg-lv <-> /dev/vg/lv)
        mount = ""
        for alias in _aliases_for_dev(lv["lv_path"] or ""):
            mount = mounts.get(alias, "")
            if mount:
                break
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

    # If nothing to show, print an empty table but also a hint to stderr.
    if not rows and not args.json:
        Console().print("[dim]No logical volumes discovered.[/dim]")
        return

    if args.json:
        print(as_json(rows))
        return
    render_table(rows, color=not args.no_color)

if __name__ == "__main__":
    main()

