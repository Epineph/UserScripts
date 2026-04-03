#!/usr/bin/env python3
"""
get_top_python_packages.py

Fetch the top-N most-downloaded Python packages (past month) from the
“A monthly dump of the 15 000 most-downloaded packages” JSON maintained at
https://hugovk.github.io/top-pypi-packages/top-pypi-packages-30-days.min.json
then:
  1. Determine which packages are available on conda-forge via `micromamba search`.
  2. Print two install commands:
     * `micromamba install -c conda-forge <conda_pkg1> <conda_pkg2> …`
     * `pip install <pip_pkgA> <pip_pkgB> …`

Usage:
    ./get_top_python_packages.py [--number N]

Options:
    -n, --number N   Number of top packages to fetch (default: 80).
"""

import argparse
import subprocess
import sys
from typing import List

import requests

# URL of the monthly minified JSON (last ~30 days)
TOP_PYPI_URL = (
    "https://hugovk.github.io/top-pypi-packages/"
    "top-pypi-packages-30-days.min.json"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fetch top PyPI packages and generate micromamba/pip install commands."
    )
    parser.add_argument(
        "-n",
        "--number",
        type=int,
        default=80,
        help="How many of the top packages to process (default: 80).",
    )
    return parser.parse_args()


def fetch_top_packages(n: int) -> List[str]:
    """
    Retrieve the top-N package names from the JSON feed.
    The JSON is expected to be an object with a "rows" list of dicts,
    each containing at least "project" and "download_count".
    """
    try:
        resp = requests.get(TOP_PYPI_URL, timeout=10)
        resp.raise_for_status()
    except requests.RequestException as e:
        sys.exit(f"❌ Failed to fetch top-packages JSON: {e}")

    data = resp.json()
    rows = data.get("rows", data if isinstance(data, list) else [])
    if not rows:
        sys.exit("❌ JSON structure unexpected: no 'rows' or list found.")

    # Extract the 'project' field from each row, up to n
    pkgs = []
    for entry in rows[:n]:
        name = entry.get("project") or entry.get("package") or entry.get("name")
        if not name:
            continue
        pkgs.append(name)
    if len(pkgs) < 1:
        sys.exit("❌ Parsed zero package names; aborting.")
    return pkgs


def is_on_conda(pkg: str) -> bool:
    """
    Return True if `micromamba search <pkg> -c conda-forge` returns any hits.
    """
    try:
        proc = subprocess.run(
            ["micromamba", "search", pkg, "-c", "conda-forge"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=True,
            text=True,
        )
        return pkg.lower() in proc.stdout.lower()
    except subprocess.CalledProcessError:
        return False


def main():
    args = parse_args()
    print(f"🔍 Fetching top {args.number} PyPI packages (past ~30 days)…")
    packages = fetch_top_packages(args.number)

    conda_pkgs, pip_pkgs = [], []
    print("🔄 Checking availability on conda-forge…")
    for pkg in packages:
        if is_on_conda(pkg):
            conda_pkgs.append(pkg)
            print(f"  ✔ {pkg}")
        else:
            pip_pkgs.append(pkg)
            print(f"  ✘ {pkg} (will use pip)")

    print("\n🎯 Ready! Install commands:\n")
    if conda_pkgs:
        print("micromamba install -c conda-forge " + " ".join(conda_pkgs))
    if pip_pkgs:
        print("pip install " + " ".join(pip_pkgs))


if __name__ == "__main__":
    main()
