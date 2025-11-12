#!/usr/bin/env python3
"""
backup_usb.py

A script to archive and compress all contents of a given directory
(e.g. USB partition mount point) into a .tar.gz or .zip file, showing
an ETA progress bar using Rich, and saving the archive to
/home/heini/Documents.

Usage:
    python3 backup_usb.py /path/to/usb --format tar.gz
    python3 backup_usb.py /path/to/usb --format zip

Arguments:
    source_dir   Path to the directory you want to back up.
    --format     Compression format: 'tar.gz' or 'zip'.
    --output-dir (optional) Where to store the archive. Defaults to /home/heini/Documents.

Example:
    python3 backup_usb.py /media/usb0 --format zip
"""

import os
import sys
import argparse
import tarfile
import zipfile
from pathlib import Path
from rich.progress import Progress

def gather_files(source_dir):
    """
    Recursively collect all file paths under source_dir.
    Returns a list of absolute file paths.
    """
    file_list = []
    for root, _, files in os.walk(source_dir):
        for name in files:
            file_list.append(os.path.join(root, name))
    return file_list

def compress_to_tar_gz(files, source_dir, output_path, progress, task_id):
    """
    Create a .tar.gz archive at output_path, adding each file one by one,
    and advancing the Rich progress bar per file.
    """
    with tarfile.open(output_path, mode="w:gz") as tar:
        for fpath in files:
            # store paths relative to the source_dir so the archive has a clean tree
            arcname = os.path.relpath(fpath, start=source_dir)
            tar.add(fpath, arcname=arcname)
            progress.update(task_id, advance=1)

def compress_to_zip(files, source_dir, output_path, progress, task_id):
    """
    Create a .zip archive at output_path, adding each file one by one,
    and advancing the Rich progress bar per file.
    """
    with zipfile.ZipFile(output_path, mode="w", compression=zipfile.ZIP_DEFLATED) as zf:
        for fpath in files:
            arcname = os.path.relpath(fpath, start=source_dir)
            zf.write(fpath, arcname=arcname)
            progress.update(task_id, advance=1)

def parse_args():
    parser = argparse.ArgumentParser(
        description="Archive and compress a directory to .tar.gz or .zip with progress."
    )
    parser.add_argument(
        "source_dir",
        type=Path,
        help="Path to the directory (e.g. USB mount point) to back up."
    )
    parser.add_argument(
        "--format",
        choices=["tar.gz", "zip"],
        required=True,
        help="Compression format to use."
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path.home() / "Documents",
        help="Where to save the archive (default: %(default)s)."
    )

    args = parser.parse_args()

    # Validate source_dir
    if not args.source_dir.is_dir():
        print(f"Error: {args.source_dir!s} is not a valid directory.", file=sys.stderr)
        sys.exit(1)

    # Ensure output directory exists
    args.output_dir.mkdir(parents=True, exist_ok=True)

    return args

def main():
    args = parse_args()
    src = str(args.source_dir.resolve())
    files = gather_files(src)
    total = len(files)

    if total == 0:
        print(f"No files found in {src!s}. Nothing to archive.")
        sys.exit(0)

    # Build an output filename with timestamp
    timestamp = Path().stat().st_mtime  # just to illustrate; replace with datetime if desired
    base_name = args.source_dir.name
    if args.format == "tar.gz":
        outfile = args.output_dir / f"{base_name}.tar.gz"
    else:
        outfile = args.output_dir / f"{base_name}.zip"

    # Run the chosen compression inside a Rich progress context
    with Progress() as progress:
        task_id = progress.add_task("[green]Compressing...", total=total)
        if args.format == "tar.gz":
            compress_to_tar_gz(files, src, str(outfile), progress, task_id)
        else:
            compress_to_zip(files, src, str(outfile), progress, task_id)

    print(f"✅ Archive created at: {outfile!s}")

if __name__ == "__main__":
    main()

