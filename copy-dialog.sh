#!/usr/bin/env python3
"""
copy_rich_recursive.py: Recursively copy files or directories with a Windows-like progress interface.

Usage:
    copy_rich_recursive.py SRC [SRC ...] DEST

Examples:
    # Copy a single folder recursively
    copy_rich_recursive.py /path/to/source_folder /path/to/destination_folder

    # Copy multiple files or mix of files and folders
    copy_rich_recursive.py file1.log file2.log /path/to/dir /another/file.txt /dest/dir

    # Use with sudo if needed:
    sudo copy_rich_recursive.py /protected/src /protected/dest

Requirements:
    - pv (pipe viewer) installed and in PATH
    - Python package: rich (install via `pip install rich`)

This script:
    1. Expands input SRC arguments (files and directories) into a flat list of file paths.
    2. Computes total size for all files to copy.
    3. Uses `pv` in numeric JSON mode to copy each file, parsing its output.
    4. Displays two progress bars:
       - Per-file progress (current file completion).
       - Global progress (aggregate over all files).
    5. Recreates directory structure under DEST as needed.

Author: ChatGPT
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

from rich.progress import (
    Progress, BarColumn, TextColumn, TimeElapsedColumn,
    TransferSpeedColumn, TimeRemainingColumn
)

def collect_files(sources):
    """
    Given a list of source paths, return a list of all file paths to copy.
    Directories are traversed recursively; files are included directly.
    """
    all_files = []
    for src in sources:
        p = Path(src)
        if p.is_dir():
            # Walk directory tree
            for f in p.rglob('*'):
                if f.is_file():
                    all_files.append(f)
        elif p.is_file():
            all_files.append(p)
        else:
            print(f"Warning: {src} does not exist or is not a file/directory", file=sys.stderr)
    return all_files


def build_dest_path(src_path, sources, dest_root):
    """
    Determine destination path for a given source file.
    Maintains relative directory structure under dest_root.
    """
    # If single file copied into a file, dest_root may be a file, but here dest_root is treated as directory
    # Compute relative path against the top-level source that matched
    for top in sources:
        top_p = Path(top)
        if top_p.is_dir() and src_path.is_relative_to(top_p):
            rel = src_path.relative_to(top_p)
            return dest_root / top_p.name / rel
    # Otherwise, place directly under dest_root
    return dest_root / src_path.name


def main():
    # ----- Parse arguments -----
    parser = argparse.ArgumentParser(
        description="Recursively copy files and folders with a progress UI."
    )
    parser.add_argument(
        'sources', nargs='+',
        help='One or more source files or directories'
    )
    parser.add_argument(
        'dest',
        help='Destination directory (will be created if it does not exist)'
    )
    args = parser.parse_args()

    src_list = args.sources
    dest_root = Path(args.dest)

    # Ensure destination root exists
    dest_root.mkdir(parents=True, exist_ok=True)

    # ----- Collect files and compute sizes -----
    files = collect_files(src_list)
    if not files:
        print("No files found to copy.", file=sys.stderr)
        sys.exit(1)

    # Compute total bytes for all files
    total_size = sum(f.stat().st_size for f in files)

    # ----- Set up Rich progress bars -----
    progress = Progress(
        TextColumn("[bold blue]{task.fields[filename]}", justify="right"),
        BarColumn(bar_width=None),
        TextColumn("{task.percentage:>3.0f}%"),
        TransferSpeedColumn(),
        TimeElapsedColumn(),
        TimeRemainingColumn(),
        TextColumn("[cyan]Total"),
        BarColumn(bar_width=None),
        TextColumn("{task.completed}/{task.total} bytes"),
        expand=True
    )

    # Single task for per-file, one for global
    file_task = progress.add_task("Copying file", filename="Initializing...", total=0)
    global_task = progress.add_task("Total progress", total=total_size)

    with progress:
        # Process each file
        for src_path in files:
            src_path = Path(src_path)
            file_size = src_path.stat().st_size

            # Determine destination file path and create parent dirs
            dest_path = build_dest_path(src_path, src_list, dest_root)
            dest_path.parent.mkdir(parents=True, exist_ok=True)

            # Update per-file task metadata
            progress.reset(file_task)
            progress.update(file_task, total=file_size, completed=0, filename=src_path.name)

            # Build pv command for the current file
            pv_cmd = [
                "pv", "--numeric", "--wait",
                "--format", '{"elapsed":%t,"bytes":%b,"rate":%r,"percent":%{progress-amount-only}}',
                "-s", str(file_size), str(src_path)
            ]

            # Launch pv subprocess
            with open(dest_path, 'wb') as out_f:
                proc = subprocess.Popen(
                    pv_cmd, stdout=out_f, stderr=subprocess.PIPE, text=True
                )
                # Read JSON updates from pv and update progress bars
                for line in proc.stderr:
                    try:
                        data = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    bytes_done = data.get("bytes", 0)
                    # Update per-file and global tasks
                    progress.update(file_task, completed=bytes_done)
                    progress.update(global_task, advance=bytes_done - progress.tasks[global_task].completed)
                proc.wait()

    print("All copies complete.")


if __name__ == '__main__':
    main()

