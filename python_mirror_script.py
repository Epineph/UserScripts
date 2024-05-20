#!/usr/bin/env python3

import requests
import numpy as np
import time
import re
from concurrent.futures import ThreadPoolExecutor, as_completed
import logging
import socket

# Set up logging
logging.basicConfig(filename='mirror_failures.log', level=logging.ERROR)

# Function to check network connectivity
def check_network():
    try:
        # Connect to a well-known host (Google DNS)
        socket.create_connection(("8.8.8.8", 53))
        return True
    except OSError:
        return False

# Function to fetch the mirror list with retries
def fetch_mirror_list(url="https://archlinux.org/mirrorlist/all/", retries=3, backoff_factor=1):
    for i in range(retries):
        try:
            response = requests.get(url, timeout=5)
            response.raise_for_status()
            return response.text
        except requests.RequestException as e:
            logging.error(f"[ERROR] Attempt {i+1} failed to fetch mirror list: {e}")
            time.sleep(backoff_factor * (2 ** i))  # Exponential backoff
    raise ConnectionError(f"Failed to fetch mirror list after {retries} attempts.")

# Function to measure response time with retries
def measure_response_time(mirror, retries=3, backoff_factor=1):
    for i in range(retries):
        try:
            start_time = time.time()
            response = requests.get(f"{mirror}core/os/x86_64/core.db", timeout=5)
            response.raise_for_status()
            end_time = time.time()
            return end_time - start_time
        except requests.RequestException as e:
            logging.error(f"[ERROR] Attempt {i+1} failed to connect to {mirror}: {e}")
            time.sleep(backoff_factor * (2 ** i))  # Exponential backoff
    return float('inf')

# Function to perform statistical analysis
def calculate_statistics(response_times):
    mean = np.mean(response_times)
    std_dev = np.std(response_times)
    std_err = std_dev / np.sqrt(len(response_times))
    return mean, std_dev, std_err

# Function to update the mirror list
def update_mirror_list(top_mirrors, mirrorlist_path="/etc/pacman.d/mirrorlist"):
    with open(mirrorlist_path, "w") as f:
        f.write("## Top mirrors generated on {}\n".format(time.strftime("%Y-%m-%d %H:%M:%S")))
        for mirror in top_mirrors:
            f.write(f"Server = {mirror}$repo/os/$arch\n")

# Main function
def main():
    if not check_network():
        print("[ERROR] No network connectivity. Please check your internet connection.")
        return

    # Fetch the mirror list
    print("[STATUS] Fetching the latest mirror list...")
    try:
        mirror_list_text = fetch_mirror_list()
    except ConnectionError as e:
        print(f"[ERROR] {e}")
        return

    # Uncomment the lines before parsing them for mirrors
    uncommented_mirror_list = re.sub(r'^#Server', 'Server', mirror_list_text, flags=re.MULTILINE)

    # Debugging: Output the first few lines of the fetched mirror list
    print("[DEBUG] Fetched mirror list sample:")
    print("\n".join(uncommented_mirror_list.splitlines()[:10]))

    # Use regex to find all mirror URLs
    mirrors = re.findall(r'^Server = (.+)\$repo/os/\$arch$', uncommented_mirror_list, re.MULTILINE)

    if not mirrors:
        print("[ERROR] No mirrors found in the fetched list.")
        return

    # Debugging: Output the first few mirrors
    print("[DEBUG] Sample of parsed mirrors:")
    print("\n".join(mirrors[:10]))

    # Measure response times
    print("[STATUS] Measuring response times for each mirror...")
    response_times = []
    failed_mirrors = 0
    max_failures = 10  # Increase the tolerance for failed mirrors

    with ThreadPoolExecutor(max_workers=10) as executor:
        future_to_mirror = {executor.submit(measure_response_time, mirror): mirror for mirror in mirrors}
        for future in as_completed(future_to_mirror):
            mirror = future_to_mirror[future]
            try:
                response_time = future.result()
                if response_time < float('inf'):
                    response_times.append(response_time)
                else:
                    failed_mirrors += 1
                    if failed_mirrors > max_failures:
                        print("[ERROR] Too many mirrors failed to respond. Aborting.")
                        return
            except Exception as e:
                logging.error(f"[ERROR] Error measuring response time for {mirror}: {e}")
                failed_mirrors += 1
                if failed_mirrors > max_failures:
                    print("[ERROR] Too many mirrors failed to respond. Aborting.")
                    return

    if not response_times:
        print("[ERROR] No mirrors responded successfully.")
        return

    # Perform statistical analysis
    print("[STATUS] Calculating statistics...")
    mean, std_dev, std_err = calculate_statistics(response_times)
    print(f"Mean response time: {mean:.4f} seconds")
    print(f"Standard deviation: {std_dev:.4f} seconds")
    print(f"Standard error: {std_err:.4f} seconds")

    # Select the top 10 mirrors
    top_mirrors_indices = np.argsort(response_times)[:10]
    top_mirrors = [mirrors[i] for i in top_mirrors_indices]

    # Update the mirror list
    print("[STATUS] Updating the system's mirror list...")
    update_mirror_list(top_mirrors)
    print("[STATUS] Mirrorlist updated.")

if __name__ == "__main__":
    main()

