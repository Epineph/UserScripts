#!/usr/bin/env python3
"""
Script: sort_installed_package_sizes.py

Description:
    Parses the output of `pacman -Qi` to extract each installed package’s
    “Installed Size,” normalizes sizes to KiB, sorts all packages by descending
    size, and prints a neatly formatted table.

Usage:
    # Make executable and run:
    $ chmod +x sort_installed_package_sizes.py
    $ ./sort_installed_package_sizes.py

    # Or via Python interpreter:
    $ python3 sort_installed_package_sizes.py

Requirements:
    - Python 3.6+
    - pacman (in your PATH)
"""

import re
import subprocess
import sys

def get_pacman_info() -> str:
    """
    Run `pacman -Qi` and return its full stdout as text.
    Exits on error.
    """
    try:
        proc = subprocess.run(
            ["pacman", "-Qi"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True
        )
    except subprocess.CalledProcessError as e:
        print(f"Error: failed to run pacman -Qi:\n{e.stderr}", file=sys.stderr)
        sys.exit(1)
    return proc.stdout

def parse_info_block(block: str):
    """
    Given a block of text for one package (lines separated by '\n'),
    extract the package name and installed size.
    Returns:
        (name: str, size_kib: float) or (None, None) if parsing fails.
    """
    name = None
    size_kib = None

    # Regex to match "Installed Size :  1 234,56 MiB" (comma or dot decimal)
    size_re = re.compile(r"Installed Size\s*:\s*([\d\.,]+)\s*(KiB|MiB|GiB)")

    for line in block.splitlines():
        if line.startswith("Name"):
            # e.g. "Name           : bash"
            parts = line.split(":", 1)
            name = parts[1].strip() if len(parts) == 2 else None

        elif line.startswith("Installed Size"):
            m = size_re.search(line)
            if m:
                num_str, unit = m.groups()
                # Normalize decimal comma → dot
                num = float(num_str.replace(",", "."))
                # Convert to KiB
                if unit == "KiB":
                    size_kib = num
                elif unit == "MiB":
                    size_kib = num * 1024
                elif unit == "GiB":
                    size_kib = num * 1024 * 1024

    return name, size_kib

def human_readable(kib: float) -> str:
    """
    Convert a size in KiB back to a human-friendly string with 2 decimals.
    """
    if kib < 1024:
        return f"{kib:.2f} KiB"
    elif kib < 1024 * 1024:
        return f"{(kib / 1024):.2f} MiB"
    else:
        return f"{(kib / (1024 * 1024)):.2f} GiB"

def main():
    # 1) Get raw pacman output
    data = get_pacman_info()

    # 2) Split into blocks (each package is separated by a blank line)
    blocks = data.strip().split("\n\n")

    # 3) Parse each block, collect (name, size_kib)
    pkg_list = []
    for block in blocks:
        name, size_kib = parse_info_block(block)
        if name:
            # Treat missing size as 0 so it sorts at the end
            pkg_list.append((name, size_kib if size_kib is not None else 0.0))

    # 4) Sort descending by size_kib
    pkg_list.sort(key=lambda x: x[1], reverse=True)

    # 5) Print table
    header_pkg = "Package"
    header_size = "Installed Size"
    print(f"{header_pkg:<30} {header_size:>15}")
    print("-" * 46)

    for name, size_kib in pkg_list:
        # If original size was missing, mark as "N/A"
        human = human_readable(size_kib) if size_kib > 0 else "N/A"
        print(f"{name:<30} {human:>15}")

if __name__ == "__main__":
    main()

