#!/usr/bin/env python3
"""
Script: query_package_sizes.py
Description:
    For each package provided as command line argument, or from a default list if no
    arguments are provided, this script calls 'pacman -Si <package>',
    extracts the "Installed Size" value, converts it to a baseline in KiB and then
    dynamically formats and prints the size in KiB, MiB, or GiB.
    
Usage:
    # Using custom packages:
    $ ./query_package_sizes.py cuda cuda-tools cudnn nvidia-dkms nvidia-settings nvidia-utils qt5 qt6 qt5-base qt6-base vulkan-headers vulkan-extra-layers volk vkmark vkd3d spirv-tools python-glfw vulkan-tools vulkan-utility-libraries archiso arch-install-scripts archinstall uutils-coreutils progress grub glib2-devel glibc-locales gcc-fortran gcc libcap-ng libcurl-compat libcurl-gnutls libgccjit grub fuse3 freetype2 libisoburn os-prober
    
    # Using default package list:
    $ ./query_package_sizes.py

Requirements:
    - Python 3.x
    - pacman (available on Arch Linux systems)
    - The pacman command must be available in the system PATH.
"""

import re
import subprocess
import sys

def query_installed_size(pkg: str) -> str:
    """
    Queries pacman for package info and extracts the Installed Size.
    
    Args:
        pkg: Package name as a string.
    
    Returns:
        A formatted string with the size and unit (e.g., "48.28 MiB"),
        or "Not found" if the package is not available.
    """
    try:
        # Run the pacman -Si command and decode its output.
        result = subprocess.run(['pacman', '-Si', pkg],
                                stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL,
                                text=True,
                                check=True)
        output = result.stdout
    except subprocess.CalledProcessError:
        return "Not found"
    
    # Look for the line that begins with "Installed Size"
    match = re.search(r"Installed Size\s*:\s*([\d\.,]+)\s*(KiB|MiB|GiB)", output)
    if not match:
        return "Not found"

    num_str, unit = match.groups()
    # Replace comma with a period for proper float conversion (locale issues).
    num_str = num_str.replace(",", ".")
    
    try:
        size_val = float(num_str)
    except ValueError:
        return "Error"
    
    # Convert the size to KiB:
    if unit == "KiB":
        size_kib = size_val
    elif unit == "MiB":
        size_kib = size_val * 1024
    elif unit == "GiB":
        size_kib = size_val * 1024 * 1024
    else:
        size_kib = size_val

    # Determine the display unit based on size in KiB:
    # - If size_kib < 1024, display in KiB.
    # - If size_kib < 1024*1024 (i.e. less than 1 GiB), display in MiB.
    # - Otherwise, display in GiB.
    if size_kib < 1024:
        display_val = size_kib
        display_unit = "KiB"
    elif size_kib < 1024 * 1024:
        display_val = size_kib / 1024
        display_unit = "MiB"
    else:
        display_val = size_kib / (1024 * 1024)
        display_unit = "GiB"
        
    return f"{display_val:.2f} {display_unit}"

def main():
    # Check if packages are provided as command-line arguments.
    if len(sys.argv) > 1:
        packages = sys.argv[1:]
    else:
        # Default package list if no arguments are provided.
        packages = [
            "devtools", "reflector", "rsync", "wget", "curl", "coreutils",
            "iptables", "inetutils", "openssh", "lvm2", "roctracer", "rocsolver",
            "rocrand", "rocm-smi-lib", "rocm-opencl-sdk", "rocm-opencl-runtime",
            "rocm-ml-libraries", "rocm-llvm", "rocm-language-runtime", "rocm-hip-sdk",
            "rocm-hip-libraries", "texlive-mathscience", "texlive-latexextra",
            "torchvision", "qt5", "qt6", "qt5-base", "qt6-base", "vulkan-radeon",
            "vulkan-headers", "vulkan-extra-layers", "volk", "vkmark", "vkd3d",
            "spirv-tools", "amdvlk", "vulkan-mesa-layers", "vulkan-tools",
            "vulkan-utility-libraries", "mesa", "mesa-demos", "archiso",
            "arch-install-scripts", "archinstall", "uutils-coreutils", "progress",
            "grub", "glib2-devel", "glibc-locales", "gcc-fortran", "gcc",
            "libcap-ng", "libcurl-compat", "libcurl-gnutls", "libgccjit", "grub",
            "fuse3", "freetype2", "libisoburn", "os-prober"
        ]
    
    # Print header for the output table.
    header_pkg = "Package"
    header_size = "Installed Size"
    print(f"{header_pkg:<30} {header_size:<20}")
    print("-" * 50)
    
    # Process each package and print the size information.
    for pkg in packages:
        size_formatted = query_installed_size(pkg)
        print(f"{pkg:<30} {size_formatted:<20}")

if __name__ == "__main__":
    main()

