#!/usr/bin/env bash
# hold-packages.sh: Add specified packages to IgnorePkg in /etc/pacman.conf
#
# Usage:
#   sudo ./hold-packages.sh <pkg1> [pkg2 ...]
#
# This script will:
#   1. Back up /etc/pacman.conf to /etc/pacman.conf.bak.<timestamp>
#   2. Check for an existing IgnorePkg line in the [options] section.
#   3. If present, merge new package names (avoiding duplicates).
#   4. If absent, insert a new IgnorePkg line after the [options] header.
#   5. Confirm the updated IgnorePkg line.

set -euo pipefail

PACMAN_CONF="/etc/pacman.conf"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
BACKUP="${PACMAN_CONF}.bak.${TIMESTAMP}"

# Ensure script is run as root
if [[ "$EUID" -ne 0 ]]; then
  echo "Error: This script must be run with root privileges (e.g., via sudo)." >&2
  exit 1
fi

# Ensure at least one package name was provided
if [[ "$#" -lt 1 ]]; then
  echo "Usage: sudo $0 <pkg1> [pkg2 ...]" >&2
  exit 1
fi

# Backup the original configuration
cp "$PACMAN_CONF" "$BACKUP"
echo "Backed up $PACMAN_CONF to $BACKUP"

# Read existing packages from IgnorePkg (if any)
if grep -qE '^IgnorePkg' "$PACMAN_CONF"; then
  # Extract existing package names
  read -ra EXISTING <<<"$(grep -E '^IgnorePkg' "$PACMAN_CONF" | sed -E 's/^IgnorePkg[[:space:]]*=[[:space:]]*//')"
else
  EXISTING=()
fi

# Combine existing and new packages, remove duplicates
declare -A unique_pkgs
for pkg in "${EXISTING[@]}" "$@"; do
  unique_pkgs["$pkg"]=1
done

# Form the merged package list
MERGED=()
for pkg in "${!unique_pkgs[@]}"; do
  MERGED+=("$pkg")
done
# Sort for consistency (requires GNU sort)
IFS=$'\n' MERGED=($(printf "%s\n" "${MERGED[@]}" | sort))
unset IFS

# Build the new IgnorePkg line
NEW_LINE="IgnorePkg = ${MERGED[*]}"

# Update or insert the line in pacman.conf
if grep -qE '^IgnorePkg' "$PACMAN_CONF"; then
  sed -i -E "s|^IgnorePkg.*|${NEW_LINE}|" "$PACMAN_CONF"
  echo "Updated IgnorePkg line to:" "$NEW_LINE"
else
  # Insert after the [options] header
  sed -i -E "/^\[options\]/a ${NEW_LINE}" "$PACMAN_CONF"
  echo "Inserted IgnorePkg line after [options]:" "$NEW_LINE"
fi

exit 0
