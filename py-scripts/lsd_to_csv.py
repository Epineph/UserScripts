#!/usr/bin/env python3
"""
lsd_to_csv.py

Export the output of `lsd` (LS DeluxE) into a CSV file, including both:
 • the textual permissions (e.g. "drwxr-xr-x")
 • the corresponding octal mode (e.g. "755")

By default, this script will:
  1. Run `lsd` in the current directory (or a user-specified one) with any extra flags.
  2. Request JSON output from `lsd` (requires lsd ≥ version supporting `--json`).
  3. Parse the JSON into Python data structures.
  4. Compute the octal mode for each entry based on its rwx string.
  5. Write a CSV file with columns for:
     permissions (rwx), octal_mode, user, group, size, modified, and name.

Usage:
    python3 lsd_to_csv.py [-h] [-d DIRECTORY] [-o OUTPUT] [--lsd-flags "FLAGS"]

Options:
  -h, --help
        Show this help message and exit.

  -d DIRECTORY, --directory DIRECTORY
        Target directory to list. Default: current directory.

  -o OUTPUT, --output OUTPUT
        Output CSV filename. Default: lsd_output.csv.

  --lsd-flags "FLAGS"
        A quoted string of extra flags to forward to `lsd`. 
        For example: "--sizesort --total-size --header --permission=\"rwx\"".
        Make sure to include leading dashes exactly as you would in the shell.
        These flags will be appended to `lsd`’s invocation in addition to `--json`.

Requirements:
  • Python 3.6+ (for built-in json and csv modules).
  • `lsd` binary in your PATH, of a version that supports `--json`.
  • No external Python dependencies required.

Example:
    # 1) Simply export the default `lsd -l` of the current directory:
    python3 lsd_to_csv.py

    # 2) Export a different directory, pass extra flags, and specify output name:
    python3 lsd_to_csv.py \
        -d /home/heini \
        -o home_listing.csv \
        --lsd-flags "-a -A -l --sizesort --total-size --header --permission=\"rwx\""

Output CSV columns (in order):
    permissions, octal_mode, user, group, size, modified, name
"""

import argparse
import subprocess
import json
import csv
import sys

def parse_args():
    """
    Parse command-line arguments.
    """
    parser = argparse.ArgumentParser(
        description="Run `lsd` in JSON mode and dump its fields into a CSV file, "
                    "including both textual and octal permissions.",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument(
        "-d", "--directory",
        default=".",
        help="Target directory to list. Default: current directory."
    )
    parser.add_argument(
        "-o", "--output",
        default="lsd_output.csv",
        help="Output CSV filename. Default: lsd_output.csv."
    )
    parser.add_argument(
        "--lsd-flags",
        default="",
        help=(
            "Quoted string of extra flags to forward to `lsd`. "
            "For example: \"-a -A -l --sizesort --total-size --header --permission=\\\"rwx\\\"\".\n"
            "These flags will be appended to `lsd`’s invocation in addition to `--json`."
        )
    )
    return parser.parse_args()

def permission_string_to_octal(perm_string):
    """
    Convert a permission string like "drwxr-xr-x" into a three-digit octal string, e.g. "755".

    Args:
        perm_string (str): A 10-character permission string from `lsd`, where:
            • the first character indicates file type (e.g. 'd' for directory, '-' for regular file).
            • the next nine characters come in three triads: user, group, other.
              Each triad is some combination of 'r', 'w', 'x', '-' (e.g. "rwx" or "r-x" or "rw-").

    Returns:
        str: A three-digit octal representation (without leading zero), e.g. "755" or "" if input is malformed.
    """
    # Guard: we expect at least 10 characters ("d" + 9 permission bits)
    if not isinstance(perm_string, str) or len(perm_string) < 10:
        return ""

    # Ignore the file-type character at index 0:
    triads = perm_string[1:10]  # this should be exactly 9 chars: e.g. "rwxr-xr-x"
    octal_digits = []

    # Break into three sets of three characters:
    for i in range(0, 9, 3):
        trio = triads[i:i+3]  # e.g. "rwx", "r-x", "r--"
        value = 0
        if trio[0] == 'r':
            value += 4
        if trio[1] == 'w':
            value += 2
        # We treat both 'x' and special bits 's'/'t' as execute for simplicity:
        if trio[2] in ('x', 's', 't'):
            value += 1
        octal_digits.append(str(value))

    # Join the three numbers, e.g. ["7","5","5"] → "755"
    return "".join(octal_digits)

def run_lsd_json(target_dir, extra_flags):
    """
    Invoke `lsd` with JSON output and return the parsed JSON list.

    Args:
        target_dir (str): Directory to list.
        extra_flags (str): Additional flags (e.g. "-a -l") to pass to lsd.

    Returns:
        list of dicts: Each dict corresponds to a single file/directory entry from `lsd`.
    """
    # Build the command array. We always include --json to ask for structured output.
    cmd = ["lsd"]
    if extra_flags:
        # Split on whitespace so that users can pass flags exactly as they would on the shell:
        cmd.extend(extra_flags.split())
    cmd.append("--json")
    cmd.append(target_dir)

    try:
        completed = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
            encoding="utf-8"
        )
    except subprocess.CalledProcessError as e:
        sys.stderr.write(
            f"\nError: `lsd` exited with status {e.returncode}.\n"
            f"Command: {' '.join(cmd)}\n"
            f"Stderr output:\n{e.stderr}\n"
        )
        sys.exit(1)

    try:
        data = json.loads(completed.stdout)
    except json.JSONDecodeError as e:
        sys.stderr.write(
            f"\nError: Failed to parse JSON output from `lsd`.\n"
            f"JSONDecodeError: {e}\n"
            f"Raw output:\n{completed.stdout}\n"
        )
        sys.exit(1)

    return data

def write_csv(records, output_filename):
    """
    Write the parsed `lsd` JSON records to a CSV file, including both textual and octal permissions.

    Columns (in this order):
      - permissions  (e.g. "drwxr-xr-x")
      - octal_mode   (e.g. "755")
      - user         (owner name, e.g. "heini")
      - group        (group name, e.g. "adm")
      - size         (integer, bytes)
      - modified     (timestamp string, e.g. "Fri Jun  6 19:50:27 2025")
      - name         (filename or directory name)

    Args:
        records (list of dict): JSON entries returned by `lsd --json`.
        output_filename (str): Path to the CSV file to create.
    """
    fieldnames = [
        "permissions",
        "octal_mode",
        "user",
        "group",
        "size",
        "modified",
        "name"
    ]

    with open(output_filename, mode="w", newline="", encoding="utf-8") as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()

        for rec in records:
            # Extract the textual rwx string (or default to empty)
            perm_str = rec.get("permissions", "")

            # Compute the octal mode from perm_str
            octal = permission_string_to_octal(perm_str)

            row = {
                "permissions": perm_str,
                "octal_mode":  octal,
                "user":        rec.get("user", ""),
                "group":       rec.get("group", ""),
                "size":        rec.get("size", ""),
                "modified":    rec.get("modified", ""),
                "name":        rec.get("name", "")
            }
            writer.writerow(row)

    print(f"Successfully wrote {len(records)} entries to '{output_filename}'.")

def main():
    args = parse_args()

    # 1) Run `lsd --json` on the directory of interest.
    print(f"Invoking: lsd {args.lsd_flags} --json {args.directory}")
    records = run_lsd_json(args.directory, args.lsd_flags)

    # 2) Write out to CSV (with both permissions and octal_mode).
    write_csv(records, args.output)

if __name__ == "__main__":
    main()

