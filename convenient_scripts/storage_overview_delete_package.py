#!/usr/bin/env python3

import subprocess
import re
import os

# Function to get the size of a package and its dependencies
def get_package_size(pkg):
    try:
        # Get list of packages that would be removed with the target package
        result = subprocess.run(
            ["pactree", "-u", pkg],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if result.returncode != 0:
            return None

        # Extract the package names
        packages = result.stdout.strip().splitlines()

        # Get the size of each package
        total_size = 0
        for package in packages:
            size_result = subprocess.run(
                ["pacman", "-Qi", package],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            if size_result.returncode == 0:
                size_info = size_result.stdout
                size_match = re.search(r"Installed Size\s+:\s+(\d+\.?\d*)\s(\w+)", size_info)
                if size_match:
                    size, unit = float(size_match.group(1)), size_match.group(2)
                    if unit == "KiB":
                        size *= 1
                    elif unit == "MiB":
                        size *= 1024
                    elif unit == "GiB":
                        size *= 1024 * 1024
                    total_size += size
        return total_size
    except Exception as e:
        print(f"Error calculating size for {pkg}: {e}")
        return None

# Get a list of all explicitly installed packages
result = subprocess.run(["pacman", "-Qqe"], stdout=subprocess.PIPE, text=True)
packages = result.stdout.strip().splitlines()

# Calculate size for each package
package_sizes = []
for pkg in packages:
    size = get_package_size(pkg)
    if size is not None:
        package_sizes.append((pkg, size))

# Sort packages by size in descending order
package_sizes.sort(key=lambda x: x[1], reverse=True)

# Format output for display
output_lines = []
for pkg, size in package_sizes[:30]:
    size_kib = size
    size_mib = size / 1024
    size_gib = size / (1024 * 1024)
    if size_gib >= 1:
        size_str = f"{size_gib:.2f} GiB"
    elif size_mib >= 1:
        size_str = f"{size_mib:.2f} MiB"
    else:
        size_str = f"{size_kib:.2f} KiB"
    output_lines.append(f"{size_str}\t{pkg}")

# Write output to a temporary file for bat
temp_file = "/tmp/largest_pkgs.txt"
with open(temp_file, "w") as f:
    f.write("\n".join(output_lines))

# Display output using bat
os.system(f"bat --paging=never --style=grid {temp_file}")

# Clean up
os.remove(temp_file)

