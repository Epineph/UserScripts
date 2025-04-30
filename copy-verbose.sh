#!/usr/bin/env bash
#───────────────────────────────────────────────────────────────────────────────
#  copy-bar.sh — Copy with a rich progress bar using 'gcp'
#
#  Requirements : gcp (AUR: yay -S gcp)
#  Author       : Your Name <you@example.com>
#───────────────────────────────────────────────────────────────────────────────
#  SYNOPSIS
#      copy-bar.sh -s <source> -t <target> [-r] [-h]
#
#  DESCRIPTION
#      • Uses 'gcp -v' for files and 'gcp -vr' for directories to display:
#         – per-file and overall progress bar
#         – ETA, throughput, count of files transferred
#      • Automatically creates target directories
#
#  OPTIONS
#      -s, --source       Path to source file or directory (required).
#      -t, --target       Path to target file or directory (required).
#      -r, --recursive    Recursively copy when the source is a directory.
#      -h, --help         Show this help and exit.
#
#  EXAMPLES
#      copy-bar.sh -s large.iso -t /mnt/usb/
#      copy-bar.sh -s ~/Documents -t /backup/Documents -r
#───────────────────────────────────────────────────────────────────────────────

set -euo pipefail
IFS=$'\n\t'

print_help() {
  cat <<EOF
Usage: $(basename "$0") -s <source> -t <target> [-r] [-h]

Copy files or directories with an illustrative progress bar using 'gcp'.

Options:
  -s, --source       Path to source file or directory (required).
  -t, --target       Path to target file or directory (required).
  -r, --recursive    Recursively copy when the source is a directory.
  -h, --help         Display this help and exit.

Examples:
  $(basename "$0") -s large.iso -t /mnt/usb/
  $(basename "$0") -s ~/Documents -t /backup/Documents -r

Requirements:
  gcp (install via AUR: yay -S gcp)

EOF
}

# ───────────────────────────────────────────────────────────────────────────────
# Parse arguments
# ───────────────────────────────────────────────────────────────────────────────
source_path="" target_path="" recursive=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--source)
      source_path="$2"; shift 2;;
    -t|--target)
      target_path="$2"; shift 2;;
    -r|--recursive)
      recursive=true; shift;;
    -h|--help)
      print_help; exit 0;;
    *)
      echo "Error: Unknown option – $1" >&2
      print_help
      exit 1
      ;;
  esac
done

# ───────────────────────────────────────────────────────────────────────────────
# Validate required options
# ───────────────────────────────────────────────────────────────────────────────
if [[ -z "$source_path" ]]; then
  echo "Error: --source is required." >&2
  exit 1
fi
if [[ -z "$target_path" ]]; then
  echo "Error: --target is required." >&2
  exit 1
fi
if [[ ! -e "$source_path" ]]; then
  echo "Error: Source '$source_path' does not exist." >&2
  exit 1
fi

# ───────────────────────────────────────────────────────────────────────────────
# Ensure 'gcp' is installed
# ───────────────────────────────────────────────────────────────────────────────
if ! command -v gcp &>/dev/null; then
  echo "Error: 'gcp' not found. Install with 'yay -S gcp'." >&2
  exit 1
fi

# ───────────────────────────────────────────────────────────────────────────────
# Perform copy
# ───────────────────────────────────────────────────────────────────────────────
if [[ -d "$source_path" ]]; then
  # Directory → require recursive flag
  if [[ "$recursive" != true ]]; then
    echo "Error: '$source_path' is a directory; add -r to copy recursively." >&2
    exit 1
  fi
  mkdir -p "$target_path"
  echo "Recursively copying directory:"
  echo "  Source: $source_path"
  echo "  Target: $target_path"
  gcp -vr "$source_path" "$target_path"
else
  # Single file
  parent_dir=$(dirname "$target_path")
  # If target ends with slash (directory), ensure it exists
  if [[ "${target_path: -1}" == "/" ]]; then
    mkdir -p "$target_path"
    echo "Copying file into directory:"
    echo "  Source: $source_path"
    echo "  Target Dir: $target_path"
    gcp -v "$source_path" "$target_path"
  else
    mkdir -p "$parent_dir"
    echo "Copying file:"
    echo "  Source: $source_path"
    echo "  Target: $target_path"
    gcp -v "$source_path" "$target_path"
  fi
fi

echo "Done."
exit 0

