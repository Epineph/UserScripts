#!/usr/bin/env python3
"""
lvm-space-pretty — Render your existing `lvm_check_space` output as a Rich table.

Default command executed: `lvm_check_space`

You can override the command via --cmd, e.g.:
  lvm-space-pretty --cmd "lvm_check_space --only-mounted"
"""

import argparse, os, re, subprocess, sys
from typing import List, Optional, Tuple

from rich.console import Console
from rich.table import Table
from rich import box

LINE_RE = re.compile(
    r"^\s*([^\s(]+)\s*\(([^)]+)\):\s*([0-9.]+[A-Za-z]+)\/([0-9.]+[A-Za-z]+)\s*\((\d+)%\s*used\)\s*$"
)


def _run_cmd(cmd: str) -> str:
    return subprocess.check_output(
        cmd, shell=True, text=True, stderr=subprocess.DEVNULL
    )


def _parse_bytes(s: str) -> int:
    s = s.strip().lower()
    # Accept 64g, 141.3g, 512m, 123k, 10t, 4096, 4096b, etc.
    m = re.match(r"^([0-9]*\.?[0-9]+)\s*([kmgtpezy]?)b?$", s)
    if not m:
        try:
            return int(s)
        except ValueError:
            return 0
    num = float(m.group(1))
    unit = m.group(2)
    mult = {
        "": 1,
        "k": 1024,
        "m": 1024**2,
        "g": 1024**3,
        "t": 1024**4,
        "p": 1024**5,
        "e": 1024**6,
        "z": 1024**7,
        "y": 1024**8,
    }[unit]
    return int(num * mult)


def _fmt_bytes(n: int) -> str:
    units = ["B", "K", "M", "G", "T", "P", "E", "Z", "Y"]
    x = float(n)
    for u in units:
        if x < 1024.0:
            return f"{x:.1f}{u}"
        x /= 1024.0
    return f"{x:.1f}Y"


def _parse_lines(text: str):
    rows = []
    for line in text.splitlines():
        m = LINE_RE.match(line)
        if not m:
            continue
        lv, mount, used_s, total_s, pct_s = m.groups()
        used_b = _parse_bytes(used_s)
        total_b = _parse_bytes(total_s)
        free_b = max(total_b - used_b, 0)
        pct = int(pct_s)
        rows.append(
            {
                "lv": lv,
                "mount": mount,
                "used_b": used_b,
                "total_b": total_b,
                "free_b": free_b,
                "pct": pct,
            }
        )
    return rows


def _render(rows, no_color: bool):
    c = Console(no_color=no_color)
    t = Table(box=box.HEAVY_HEAD, header_style="bold cyan", show_lines=False)
    t.add_column("LV", style="dim", no_wrap=True)
    t.add_column("MOUNT")
    t.add_column("USED", justify="right")
    t.add_column("FREE", justify="right")
    t.add_column("TOTAL", justify="right")
    t.add_column("%USED", justify="right")

    for r in rows:
        if r["pct"] >= 90:
            pct_s = f"[bold red]{r['pct']}%[/]"
        elif r["pct"] >= 75:
            pct_s = f"[yellow]{r['pct']}%[/]"
        else:
            pct_s = f"[green]{r['pct']}%[/]"
        t.add_row(
            r["lv"],
            r["mount"],
            _fmt_bytes(r["used_b"]),
            _fmt_bytes(r["free_b"]),
            _fmt_bytes(r["total_b"]),
            pct_s,
        )
    c.print(t)


def main():
    ap = argparse.ArgumentParser(description="Pretty table for lvm_check_space output.")
    ap.add_argument(
        "--cmd",
        default="lvm_check_space",
        help="Command to run whose output is parsed (default: lvm_check_space)",
    )
    ap.add_argument("--no-color", action="store_true", help="Disable colours.")
    args = ap.parse_args()

    try:
        out = _run_cmd(args.cmd)
    except subprocess.CalledProcessError:
        print("ERROR: Failed to run command:", args.cmd, file=sys.stderr)
        sys.exit(1)

    rows = _parse_lines(out)
    if not rows:
        Console().print(
            "[dim]No rows parsed. Ensure the command outputs lines like 'name (/mount): 64G/123G (52% used)'.[/dim]"
        )
        sys.exit(2)

    _render(rows, no_color=args.no_color)


if __name__ == "__main__":
    main()
