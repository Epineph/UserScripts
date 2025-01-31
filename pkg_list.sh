#!/bin/bash
#
# List installed packages from pacman and specified AUR helpers, save as CSV, and generate reinstall command.
#
# Usage:
#   ./list_installed_packages.sh [aur_helpers]
#   Example: ./list_installed_packages.sh "yay paru"
#   Example: ./list_installed_packages.sh "yay,paru,trizen"
#

# Default AUR helpers (can be overridden via argument)
AUR_HELPERS="yay paru"

# If user provides a list, override default AUR helpers
if [[ -n "$1" ]]; then
    AUR_HELPERS=$(echo "$1" | tr ',' ' ')  # Convert comma-separated list to space-separated
fi

OUTPUT_FILE="$HOME/installed_packages.csv"

echo "Scanning installed packages..."
echo "Package,Installed With" > "$OUTPUT_FILE"

# Pacman packages
pacman -Qqen | awk '{print $1",pacman"}' >> "$OUTPUT_FILE"

# AUR packages from each helper
for HELPER in $AUR_HELPERS; do
    if command -v "$HELPER" &> /dev/null; then
        echo "Using $HELPER to list AUR packages..."
        $HELPER -Qqem | awk -v helper="$HELPER" '{print $1","helper}' >> "$OUTPUT_FILE"
    else
        echo "Warning: AUR helper '$HELPER' not found. Skipping..."
    fi
done

echo "Packages saved to: $OUTPUT_FILE"

# Generate reinstall command
REINSTALL_CMD="yay -S $(awk -F',' 'NR>1 {print $1}' "$OUTPUT_FILE")"
echo -e "\nTo reinstall all packages, run:\n$REINSTALL_CMD"

