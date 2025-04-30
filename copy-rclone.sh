#!/usr/bin/env bash
#───────────────────────────────────────────────────────────────────────────────
#  copy-bar-rclone.sh — Copy with a rich progress bar using rclone
#
#  Requirements : rclone (install via pacman: sudo pacman -S rclone)
#  Author       : Your Name <you@example.com>
#───────────────────────────────────────────────────────────────────────────────
#  SYNOPSIS
#      copy-bar-rclone.sh -s <source> -t <target> [-r] [-h]
#
#  DESCRIPTION
#      • Uses 'rclone copyto' for single files and 'rclone copy' for directories.
#      • Displays a dynamic progress bar, ETA, throughput, and file counts.
#      • Automatically creates any missing target directories.
#
#  OPTIONS
#      -s, --source       Path to source file or directory (required).
#      -t, --target       Path to target file or directory (required).
#      -r, --recursive    Recursively copy when the source is a directory.
#      -h, --help         Show this help and exit.
#
#  EXAMPLES
#      copy-bar-rclone.sh -s big.iso      -t /mnt/usb/
#      copy-bar-rclone.sh -s ~/Docs       -t /backup/Documents -r
#───────────────────────────────────────────────────────────────────────────────

set -euo pipefail
IFS=$'\n\t'

print_help() {
  cat <<EOF
Usage: $(basename "$0") -s <source> -t <target> [-r] [-h]

Copy files or directories with an illustrative progress bar using rclone.

Options:
  -s, --source       Path to source file or directory (required).
  -t, --target       Path to target file or directory (required).
  -r, --recursive    Recursively copy when the source is a directory.
  -h, --help         Display this help and exit.

Examples:
  $(basename "$0") -s big.iso -t /mnt/usb/
  $(basename "$0") -s ~/Documents -t /backup/Documents -r

Requirements:
  rclone (install via pacman: sudo pacman -S rclone)
EOF
}

# ───────────────────────────────────────────────────────────────────────────────
# 1) Parse arguments
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
      echo "Error: Unknown option: $1" >&2
      print_help
      exit 1
      ;;
  esac
done

# ───────────────────────────────────────────────────────────────────────────────
# 2) Validate mandatory parameters
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
# 3) Ensure rclone is available
# ───────────────────────────────────────────────────────────────────────────────
if ! command -v rclone &>/dev/null; then
  echo "Error: 'rclone' not found. Install with 'sudo pacman -S rclone'." >&2
  exit 1
fi

# ───────────────────────────────────────────────────────────────────────────────
# 4) Perform copy
# ───────────────────────────────────────────────────────────────────────────────
if [[ -f "$source_path" ]]; then
  # ─── Single file ─────────────────────────────────────────────────────────────
  parent_dir=$(dirname "$target_path")
  mkdir -p "$parent_dir"
  printf "Copying file:\n  %s → %s\n\n" "$source_path" "$target_path"
  rclone copyto \
    "$source_path" "$target_path" \
    --progress

elif [[ -d "$source_path" ]]; then
  # ─── Directory ───────────────────────────────────────────────────────────────
  if [[ "$recursive" != true ]]; then
    echo "Error: '$source_path' is a directory; add -r to copy recursively." >&2
    exit 1
  fi

  # Determine where to place the directory:
  if [[ -d "$target_path" ]]; then
    dest_path="${target_path%/}/$(basename "$source_path")"
  else
    dest_path="$target_path"
  fi

  mkdir -p "$dest_path"
  printf "Recursively copying directory:\n  %s → %s\n\n" \
    "$source_path" "$dest_path"

  # Trailing slashes ensure we copy CONTENTS of source into dest
  rclone copy \
    "${source_path%/}/" "${dest_path%/}/" \
    --progress

else
  echo "Error: '$source_path' is neither a file nor a directory." >&2
  exit 1
fi

echo -e "\nDone."
exit 0

