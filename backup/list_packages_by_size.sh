#!/usr/bin/env python3
#===============================================================================
# Name: list_installed_packages_descending_by_size.py
#
# Description:
#   This script lists all installed Arch Linux packages with their installed size,
#   sorted in descending order (largest to smallest). By default, it displays the
#   top 50 packages.
#
# Usage:
#   1. Make this script executable:
#         chmod +x list_installed_packages_descending_by_size.py
#   2. Run it:
#         ./list_installed_packages_descending_by_size.py [NUMBER_OF_PACKAGES]
#      where NUMBER_OF_PACKAGES (optional) is how many results (largest packages)
#      to display.
#
# Requirements:
#   - Python 3.x
#   - Arch Linux with pacman available
#
#===============================================================================

import subprocess
import sys
import re

def parse_installed_size(size_str):
    """
    Parse the 'Installed Size' string from pacman -Qi output.
    
    Parameters
    ----------
    size_str : str
        A string containing a numeric value followed by a unit
        (e.g. '41.99 MiB', '256.00 KiB', '1024 B').
    
    Returns
    -------
    float
        The size in bytes as a floating-point value.
    
    Notes
    -----
    - Arch pacman typically reports sizes in B, KiB, MiB, or GiB.
    - We convert everything to bytes for consistent comparisons.
    """
    parts = size_str.split()
    if len(parts) < 2:
        # If no unit is found, we treat it as bytes (fallback).
        try:
            return float(parts[0])
        except:
            return 0.0
    
    number_str, unit = parts[0], parts[1]
    
    try:
        size_value = float(number_str)
    except ValueError:
        size_value = 0.0
    
    # Dictionary for unit conversion to bytes
    unit_multipliers = {
        'B':   1,
        'KiB': 1024,
        'MiB': 1024**2,
        'GiB': 1024**3
    }
    
    # If the unit isn't recognized, treat it as bytes
    multiplier = unit_multipliers.get(unit, 1)
    
    return size_value * multiplier

def get_installed_packages_info():
    """
    Retrieve installed package information from pacman -Qi.
    
    Returns
    -------
    list of tuples
        Each tuple is (package_name, size_in_bytes).
    """
    try:
        pacman_output = subprocess.check_output(["pacman", "-Qi"], text=True)
    except subprocess.CalledProcessError as e:
        print("Error calling pacman:", e)
        sys.exit(1)
    
    # Split the output into chunks, each chunk corresponds to one package.
    package_chunks = pacman_output.strip().split("\n\n")
    
    packages_info = []
    
    for chunk in package_chunks:
        # Regex to find 'Name' and 'Installed Size' lines
        name_match = re.search(r'^Name\s*:\s*(.*)$', chunk, re.MULTILINE)
        size_match = re.search(r'^Installed Size\s*:\s*(.*)$', chunk, re.MULTILINE)
        
        if name_match and size_match:
            pkg_name = name_match.group(1).strip()
            raw_size = size_match.group(1).strip()  # e.g. "41.99 MiB"
            size_bytes = parse_installed_size(raw_size)
            packages_info.append((pkg_name, size_bytes))
    
    return packages_info

def main():
    """
    Main function to list installed Arch Linux packages by size (descending).
    
    Steps:
    1. Retrieve installed package info via get_installed_packages_info().
    2. Sort by size in descending order.
    3. Print the results up to a user-specified or default limit.
    """
    # Check if user provided a limit (50 by default)
    if len(sys.argv) > 1:
        try:
            limit = int(sys.argv[1])
        except ValueError:
            limit = 50
    else:
        limit = 50
    
    packages_info = get_installed_packages_info()
    # Sort descending (largest to smallest)
    packages_info.sort(key=lambda x: x[1], reverse=True)
    
    # Print header
    print(f"{'Rank':>4} | {'Package':<40} | {'Size (bytes)':>15}")
    print("-" * 65)
    
    # Print up to `limit` packages
    for i, (pkg_name, size_bytes) in enumerate(packages_info[:limit], start=1):
        print(f"{i:4d} | {pkg_name:<40} | {int(size_bytes):>15d}")

if __name__ == "__main__":
    main()

