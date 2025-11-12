#!/usr/bin/env python3
"""
AUR Popularity Wrapper Script

This script queries the Arch User Repository (AUR) for packages matching a search term,
sorts them by the number of votes (used here as a measure of popularity), and enumerates
them from the most popular (rank 1) downwards.

Usage:
    python aur_popularity_wrapper.py
    Then enter your search term when prompted.

Requirements:
    - Python 3.x
    - requests (install via pip if necessary: pip install requests)
"""

import requests  # For making HTTP requests to the AUR RPC API
import json      # For parsing JSON responses

def search_aur(query):
    """
    Query the AUR RPC API for packages matching the search query.
    
    Args:
        query (str): The search term for package names.
        
    Returns:
        list: A list of package dictionaries returned by the API.
    """
    # Construct the API URL. The parameter 'v=5' specifies the API version,
    # and 'type=search' indicates that we are performing a search.
    url = f"https://aur.archlinux.org/rpc/?v=5&type=search&arg={query}"
    
    try:
        response = requests.get(url)
        response.raise_for_status()  # Raise an error if the request was unsuccessful
        data = response.json()       # Parse JSON response
        
        # Return the list of packages under the 'results' key.
        return data.get("results", [])
    except requests.RequestException as e:
        print(f"Error fetching data from AUR: {e}")
        return []

def enumerate_by_popularity(packages):
    """
    Sort packages by their vote count and print them enumerated.
    
    Args:
        packages (list): A list of package dictionaries.
    """
    # Sort packages by the 'Votes' field in descending order.
    sorted_packages = sorted(packages, key=lambda pkg: pkg.get("Votes", 0), reverse=True)
    
    # Enumerate the sorted packages starting at 1.
    for idx, pkg in enumerate(sorted_packages, start=1):
        name = pkg.get("Name", "Unknown")
        votes = pkg.get("Votes", 0)
        print(f"{idx}: {name} ({votes} votes)")

def main():
    """
    Main function to run the AUR popularity enumeration.
    """
    # Prompt the user for a search term.
    query = input("Enter a search term for AUR packages: ").strip()
    if not query:
        print("No search term provided. Exiting.")
        return
    
    # Retrieve matching packages from AUR.
    packages = search_aur(query)
    if not packages:
        print("No packages found or there was an error in fetching the data.")
        return
    
    # Enumerate the packages by popularity.
    enumerate_by_popularity(packages)

if __name__ == "__main__":
    main()

