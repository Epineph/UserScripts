#!/usr/bin/env python3
"""
Script: list_installed_packages_descending_by_size.py
Description:
    Lists all installed Arch Linux packages with their installed size (in bytes),
    sorted from largest to smallest. Additionally, when used with the -d/--delete flag,
    it allows for removal of selected packages.
    
Usage:
    Listing mode (default):
        ./list_installed_packages_descending_by_size.py [-l LIMIT]
        - LIMIT: number of packages to display (default: 50)
    
    Delete mode:
        ./list_installed_packages_descending_by_size.py -d "indices"
        - indices: A string with package indices to delete. Accepts comma/space-separated
                   values and ranges (e.g. "1,2,4-6"). If omitted, a limited package table (as per -l)
                   will be displayed before prompting.
    
Requirements:
    - Python 3.x
    - Arch Linux with pacman available
"""

import subprocess
import sys
import re
import argparse

def parse_installed_size(size_str):
    """
    Parse the 'Installed Size' string from pacman -Qi output.
    
    Parameters
    ----------
    size_str : str
        A string containing a numeric value followed by a unit (e.g., '41.99 MiB', '256.00 KiB', '1024 B').
    
    Returns
    -------
    float
        The size in bytes.
    """
    parts = size_str.split()
    if len(parts) < 2:
        try:
            return float(parts[0])
        except:
            return 0.0
    number_str, unit = parts[0], parts[1]
    try:
        size_value = float(number_str)
    except ValueError:
        size_value = 0.0
    # Unit conversion to bytes
    unit_multipliers = {
        'B':   1,
        'KiB': 1024,
        'MiB': 1024**2,
        'GiB': 1024**3
    }
    multiplier = unit_multipliers.get(unit, 1)
    return size_value * multiplier

def get_installed_packages_info():
    """
    Retrieve installed package information using pacman -Qi.
    
    Returns
    -------
    list of tuples
        Each tuple is (package_name, size_in_bytes).
    """
    try:
        # Force pacman output to English by setting LC_ALL
        pacman_output = subprocess.check_output(
            ["env", "LC_ALL=C", "pacman", "-Qi"],
            text=True
        )
    except subprocess.CalledProcessError as e:
        print("Error calling pacman:", e)
        sys.exit(1)
    
    # Split output into chunks (each chunk corresponds to one package)
    package_chunks = pacman_output.strip().split("\n\n")
    packages_info = []
    for chunk in package_chunks:
        # Extract package name and installed size using regex (case-insensitive)
        name_match = re.search(r'^Name\s*:\s*(.*)$', chunk, re.MULTILINE | re.IGNORECASE)
        size_match = re.search(r'^Installed Size\s*:\s*(.*)$', chunk, re.MULTILINE | re.IGNORECASE)
        if name_match and size_match:
            pkg_name = name_match.group(1).strip()
            raw_size = size_match.group(1).strip()  # e.g., "41.99 MiB"
            size_bytes = parse_installed_size(raw_size)
            packages_info.append((pkg_name, size_bytes))
    return packages_info

def parse_indices(indices_str):
    """
    Parse a string containing package indices and ranges.
    
    Examples:
        "1,2,4-6" or "11 23 34" or "4-10"
        => Returns a sorted list of unique indices (1-indexed).
    
    Parameters
    ----------
    indices_str : str
        String containing the indices.
        
    Returns
    -------
    list of int
        Sorted list of package indices.
    """
    indices_set = set()
    # Replace commas with spaces and split on whitespace
    tokens = indices_str.replace(',', ' ').split()
    for token in tokens:
        if '-' in token:
            try:
                start, end = token.split('-', 1)
                start = int(start)
                end = int(end)
                # Add the full range (inclusive)
                if start <= end:
                    indices_set.update(range(start, end + 1))
                else:
                    indices_set.update(range(end, start + 1))
            except ValueError:
                continue
        else:
            try:
                index = int(token)
                indices_set.add(index)
            except ValueError:
                continue
    return sorted(indices_set)

def print_packages_table(packages, limit=None):
    """
    Print a formatted table of packages.
    
    Parameters
    ----------
    packages : list of tuples
        The list of packages, where each tuple is (package_name, size_in_bytes).
    limit : int or None
        If provided, only the top 'limit' packages are printed.
        If None, all packages are printed.
    """
    print(f"{'Rank':>4} | {'Package':<40} | {'Size (bytes)':>15}")
    print("-" * 65)
    display_list = packages if limit is None else packages[:limit]
    for i, (pkg_name, size_bytes) in enumerate(display_list, start=1):
        print(f"{i:4d} | {pkg_name:<40} | {int(size_bytes):>15d}")

def delete_packages(packages, indices):
    """
    Delete the packages corresponding to the provided indices from the sorted package list.
    
    Parameters
    ----------
    packages : list of tuples
        Sorted package list (each tuple is (package_name, size_in_bytes)).
    indices : list of int
        List of 1-indexed positions to delete.
    """
    packages_to_delete = []
    for idx in indices:
        if 1 <= idx <= len(packages):
            pkg_name = packages[idx - 1][0]
            packages_to_delete.append(pkg_name)
        else:
            print(f"Index {idx} is out of range.")
    
    if not packages_to_delete:
        print("No valid packages selected for deletion.")
        return
    
    # Display the packages selected for deletion
    print("\nThe following packages will be removed:")
    for pkg in packages_to_delete:
        print(f"  - {pkg}")
    
    # Confirmation prompt
    response = input("Are you sure you want to delete these packages? (y/n): ")
    if response.lower() != 'y':
        print("Deletion cancelled.")
        return
    
    # Proceed to remove each package using pacman
    for pkg in packages_to_delete:
        print(f"Removing package: {pkg}")
        try:
            # Using sudo to ensure proper permissions
            subprocess.run(["sudo", "pacman", "-R", pkg], check=True)
        except subprocess.CalledProcessError as e:
            print(f"Failed to remove package {pkg}: {e}")

def main():
    """
    Main function to list packages or delete selected packages based on command-line arguments.
    
    Modes:
      - Listing: Displays the top packages sorted by size (default limit: 50).
      - Deletion: Removes packages corresponding to provided indices.
          * If indices are provided with -d, the full package list is used (allowing selection beyond the top limit).
          * If no indices are provided with -d, a limited table (as per -l) is shown for selection.
    """
    parser = argparse.ArgumentParser(
        description="List installed Arch Linux packages sorted by size (descending). Optionally delete packages by indices."
    )
    parser.add_argument(
        "-l", "--limit", type=int, default=50,
        help="Number of packages to display (default: 50) in listing mode or interactive delete mode."
    )
    parser.add_argument(
        "-d", "--delete", type=str, nargs='?', const='', default=None,
        help="Indices of packages to delete. Accepts comma/space-separated values and ranges (e.g. '1,2,4-6'). If omitted, a limited package table will be displayed before prompting."
    )
    
    args = parser.parse_args()
    
    # Retrieve and sort package information
    packages_info = get_installed_packages_info()
    packages_info.sort(key=lambda x: x[1], reverse=True)
    
    if args.delete is not None:
        if args.delete.strip() == "":
            # Interactive deletion mode: show a table limited by the provided -l value.
            display_limit = args.limit
            print(f"Interactive delete mode. Here are the top {display_limit} packages:\n")
            displayed_packages = packages_info[:display_limit]
            print_packages_table(displayed_packages)
            indices_input = input("\nPlease enter package indices to delete (based on above list): ")
            indices = parse_indices(indices_input)
            if not indices:
                print("No valid indices provided for deletion.")
                sys.exit(1)
            delete_packages(displayed_packages, indices)
        else:
            # Non-interactive delete mode: use the full package list.
            indices_input = args.delete
            indices = parse_indices(indices_input)
            if not indices:
                print("No valid indices provided for deletion.")
                sys.exit(1)
            delete_packages(packages_info, indices)
    else:
        # Listing mode: Display only the top packages up to the provided limit.
        print_packages_table(packages_info, limit=args.limit)

if __name__ == "__main__":
    main()

