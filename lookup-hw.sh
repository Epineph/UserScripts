#!/usr/bin/env bash
#
# lookup-hw.sh — detect hardware and search for related packages
#
# Usage:
#   lookup-hw.sh [--no-aur]
#   lookup-hw.sh -h | --help
#
# Options:
#   --no-aur    Skip searching the AUR (if you don’t have an AUR helper).
#   -h, --help  Show this help message and exit.
#

set -euo pipefail

show_help() {
  sed -n '1,20p' "$0"
}

# 1) Dump PCI and USB devices
echo "=== PCI devices (with vendor:device IDs) ==="
lspci -nnk
echo
echo "=== USB devices ==="
lsusb
echo

# 2) Ask user for a search term
read -p "Enter vendor name or ID to search for packages (e.g. 'Microchip', '1d50:6150'): " term
if [[ -z "$term" ]]; then
  echo "No search term entered; exiting."
  exit 1
fi

# 3) Search official repos
echo
echo ">>> Searching official Arch repos for '$term'..."
pacman -Ss "$term" || echo "No matches in official repos."

# 4) Optionally search the AUR (requires `yay` or similar)
if [[ "${1-}" != "--no-aur" ]]; then
  if command -v yay &>/dev/null; then
    echo
    echo ">>> Searching AUR (via yay) for '$term'..."
    yay -Ss "$term" || echo "No matches in AUR."
  else
    echo
    echo ">>> Skipping AUR search (no AUR helper found)."
  fi
fi

