#!/usr/bin/env python3
"""
copy_rich_recursive.py: Recursively copy files or directories with a Windows-like progress interface.

Usage:
    copy_rich_recursive.py SRC [SRC ...] DEST

Examples:
    # Copy a single folder recursively:
    copy_rich_recursive.py /path/to/src_folder /path/to/dest_folder

    # Copy only contents of a folder:
    copy_rich_recursive.py /path/to/src_folder/* /path/to/dest_folder

    # Copy multiple sources:
    copy_rich_recursive.py file1.log file2.log /dir1 /dir2 /dest/dir

    # With sudo:
    sudo copy_rich_recursive.py /protected/src /protected/dest

Requirements:
    - pv (pipe viewer) installed and in PATH
    - Python package: rich (install via `pip install rich`)

This script:
    1. Parses one or more sources (files or directories) from the command line.
    2. Recursively collects files under directories; includes files given directly.
    3. Computes the total byte size of all files.
    4. Recreates source hierarchy under DEST; creates missing directories.
    5. Uses `pv` in numeric JSON mode to monitor each file's copy progress.
    6. Displays per-file and aggregate progress bars with Rich.
"""
import argparse
import json
import sys
from pathlib import Path
import subprocess

from rich.progress import (
    Progress, BarColumn, TextColumn, TimeElapsedColumn,
    TransferSpeedColumn, TimeRemainingColumn
)

def collect_files(sources):
    """
    Expand source paths to a flat list of files.
    Directories are traversed recursively; files are included as-is.
    """
    all_files = []
    for src in sources:
        p = Path(src)
        if p.is_dir():
            for f in p.rglob('*'):
                if f.is_file():
                    all_files.append(f)
        elif p.is_file():
            all_files.append(p)
        else:
            print(f"Warning: {src} not found or unsupported", file=sys.stderr)
    return all_files


def build_dest_path(src_path, sources, dest_root):
    """
    Compute destination path while preserving directory structure.
    Top-level directories are recreated under dest_root.
    """
    for top in sources:
        top_p = Path(top)
        if top_p.is_dir() and Path(src_path).is_relative_to(top_p):
            rel = Path(src_path).relative_to(top_p)
            return dest_root / top_p.name / rel
    return dest_root / Path(src_path).name


def main():
    # Argument parsing
    parser = argparse.ArgumentParser(
        description="Recursively copy with Windows-like progress UI."
    )
    parser.add_argument('sources', nargs='+',
                        help='Source files or directories (shell wildcard expansion OK)')
    parser.add_argument('dest',
                        help='Destination directory (created if absent)')
    args = parser.parse_args()

    src_list = args.sources
    dest_root = Path(args.dest)
    dest_root.mkdir(parents=True, exist_ok=True)

    # Collect and size files
    files = collect_files(src_list)
    if not files:
        print("No files to copy.", file=sys.stderr)
        sys.exit(1)
    total_bytes = sum(f.stat().st_size for f in files)

    # Set up Rich progress bars
    progress = Progress(
        TextColumn("[bold blue]{task.fields[filename]}", justify="right"),
        BarColumn(bar_width=None),
        TextColumn("{task.percentage:>3.0f}%"),
        TransferSpeedColumn(),
        TimeElapsedColumn(),
        TimeRemainingColumn(),
        TextColumn("[cyan]Total:"),
        BarColumn(bar_width=None),
        TextColumn("{task.completed}/{task.total} bytes"),
        expand=True
    )

    # One task for per-file, one for global
    file_task = progress.add_task("file", filename="Initializing...", total=0)
    global_task = progress.add_task("total", filename="Total", total=total_bytes)

    with progress:
        for src in files:
            size = src.stat().st_size
            # Determine destination and ensure directory exists
            dest_path = build_dest_path(src, src_list, dest_root)
            dest_path.parent.mkdir(parents=True, exist_ok=True)

            # Reset per-file progress
            progress.reset(file_task)
            progress.update(file_task, total=size, completed=0, filename=src.name)
            last = 0

            # pv pipeline setup
            pv_cmd = [
                "pv", "--numeric", "--wait",
                "--format", '{"bytes":%b}',
                "-s", str(size), str(src)
            ]

            # Run pv and update bars
            with open(dest_path, 'wb') as out_f:
                proc = subprocess.Popen(
                    pv_cmd, stdout=out_f, stderr=subprocess.PIPE, text=True
                )
                for line in proc.stderr:
                    try:
                        data = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    done = data.get("bytes", 0)
                    delta = done - last
                    last = done
                    progress.update(file_task, completed=done)
                    progress.update(global_task, advance=delta)
                proc.wait()

    print("Copy complete.")

if __name__ == '__main__':
    main()

