#!/usr/bin/env bash
#
# show_dir_usage.sh
#
# A script that shows a directory tree (with cumulative sizes) up to DEPTH le
vels
# using `tree --du`, plus a sorted `du` listing. Both TARGET and DEPTH can be
# provided as command-line arguments, or you’ll be prompted if they’re missin
g.
#
# Usage examples:
#   ./show_dir_usage.sh /home/heini 2
#   ./show_dir_usage.sh /home/heini      # prompts for DEPTH
#   ./show_dir_usage.sh                  # prompts for TARGET, then DEPTH
#

set -euo pipefail

# --- Function: Show help message ---
show_help() {
  cat <<EOF
Usage: $(basename "$0") [TARGET] [DEPTH]

Shows a directory tree (with cumulative sizes) up to DEPTH levels using 'tree
 --du'
and a sorted 'du' listing. Both TARGET and DEPTH can be provided as command-l
ine
arguments, or you'll be prompted if they're missing.

Options:
  -h, --help    Show this help message and exit.

Examples:
  1) Provide both arguments:
     ./show_dir_usage.sh /home/heini 2

  2) Provide just one argument (TARGET), script will prompt for DEPTH:
     ./show_dir_usage.sh /home/heini

  3) Provide no arguments at all, script will prompt for both TARGET and DEPT
H:
     ./show_dir_usage.sh

EOF
}

# --- Check for help flags ---
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  show_help
  exit 0
fi

# --- Capture or prompt for TARGET ---
if [ "${1:-}" != "" ]; then
  TARGET="$1"
else
  read -rp "Enter the directory to scan (TARGET): " TARGET
fi

# --- Capture or prompt for DEPTH ---
if [ "${2:-}" != "" ]; then
  DEPTH="$2"
else
  read -rp "Enter the directory depth (DEPTH): " DEPTH
fi

# --- Check if tree is installed ---
if ! command -v tree &> /dev/null; then
  echo "Error: The 'tree' command is not installed. Please install it (e.g., 
'sudo pacman -S tree')"
  exit 1
fi

# --- Show a tree with cumulative sizes up to DEPTH ---
echo "===== Tree of '$TARGET' (Depth: $DEPTH) ====="
tree -d -h --du -L "$DEPTH" "$TARGET"

echo
echo "===== Sorted Directory Listing (Depth: $DEPTH) ====="
du -h --max-depth="$DEPTH" "$TARGET" 2>/dev/null | sort -hr | head -n 20
