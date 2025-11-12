#!/usr/bin/env python3
"""
AUR Tarball Fetcher

This script queries the AUR RPC interface for a given package name,
retrieves its source links, and filters for tarball URLs (e.g., .tar.gz, .tar.xz, or .zip).

Usage:
    python fetch_aur_tarball.py <package_name>

Example:
    python fetch_aur_tarball.py screencloud
"""

import sys
import requests

def fetch_aur_package_sources(package_name):
    """
    Fetch package information from the AUR RPC interface.
    
    The RPC endpoint returns a JSON object containing package details.
    We then extract the 'Source' field which is an array of source links.
    
    :param package_name: The name of the AUR package.
    :return: A list of source URLs or None if not found.
    """
    # Construct the RPC URL (v=5 is the API version)
    url = f"https://aur.archlinux.org/rpc/?v=5&type=info&arg[]={package_name}"
    response = requests.get(url)
    data = response.json()
    
    if data.get('resultcount', 0) == 0:
        print(f"No package found for '{package_name}'.")
        return None
    
    # Extract the first (and only) result.
    result = data.get('results')[0]
    # The source links are provided in the 'Source' field (as a list).
    sources = result.get('Source', [])
    
    return sources

def filter_tarball_urls(sources):
    """
    Filter the source URLs for common tarball file extensions.
    
    :param sources: List of source URLs.
    :return: List of URLs that appear to be tarballs.
    """
    tarball_exts = ('.tar.gz', '.tar.xz', '.zip')
    return [src for src in sources if src.endswith(tarball_exts)]

def main():
    if len(sys.argv) < 2:
        print("Usage: python fetch_aur_tarball.py <package_name>")
        sys.exit(1)
    
    package_name = sys.argv[1]
    sources = fetch_aur_package_sources(package_name)
    
    if sources is None:
        sys.exit(1)
    
    tarball_urls = filter_tarball_urls(sources)
    
    if tarball_urls:
        print("Found tarball URL(s):")
        for url in tarball_urls:
            print(url)
    else:
        print("No tarball URLs found in the package sources.")

if __name__ == "__main__":
    main()

