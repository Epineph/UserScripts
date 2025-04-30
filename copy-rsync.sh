#!/usr/bin/env bash
#───────────────────────────────────────────────────────────────────────────────
#  copy-bar-rsync.sh — copy with a rich progress bar using rsync
#
#  Requirements : rsync (install via pacman: sudo pacman -S rsync)
#  Author       : Your Name <you@example.com>
#───────────────────────────────────────────────────────────────────────────────
#  SYNOPSIS
#      copy-bar-rsync.sh -s <source> -t <target> [-r] [-h]
#
#  DESCRIPTION
#      • Uses `rsync --info=progress2 --stats -h` to display:
#        – Per-file and overall progress bars  
#        – ETA, throughput, transferred bytes  
#        – Final summary including file counts, total bytes, transfer rate  
#      • Mirrors `cp`/`cp -r` semantics, requiring `-r` for directories.  
#      • Creates any missing parent directories automatically.
#
#  OPTIONS
#      -s, --source       Path to source file or directory (required).
#      -t, --target       Path to target file or directory (required).
#      -r, --recursive    Recursively copy when the source is a directory.
#      -h, --help         Show this help and exit.
#
#  EXAMPLES
#      copy-bar-rsync.sh -s large.iso -t /mnt/usb/
#      copy-bar-rsync.sh -s ~/Documents -t /backup/Documents -r
#───────────────────────────────────────────────────────────────────────────────

set -euo pipefail
IFS=$'\n\t'

print_help() {
  cat <<EOF
Usage: $(basename "$0") -s <source> -t <target> [-r] [-h]

Copy files or directories with an illustrative progress bar using rsync.

Options:
  -s, --source       Path to source file or directory (required).
  -t, --target       Path to target file or directory (required).
  -r, --recursive    Recursively copy when the source is a directory.
  -h, --help         Display this help and exit.

Examples:
  $(basename "$0") -s large.iso -t /mnt/usb/
  $(basename "$0") -s ~/Documents -t /backup/Documents -r

Requirements:
  rsync (install via pacman: sudo pacman -S rsync)
EOF
}

# ───────────────────────────────────────────────────────────────────────────────
# 1) Parse arguments
# ───────────────────────────────────────────────────────────────────────────────
src="" dst="" recursive=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--source)
      src="$2"; shift 2;;
    -t|--target)
      dst="$2"; shift 2;;
    -r|--recursive)
      recursive=true; shift;;
    -h|--help)
      print_help; exit 0;;
    *)
      echo "Error: Unknown option: $1" >&2
      print_help
      exit 1;;
  esac
done

# ───────────────────────────────────────────────────────────────────────────────
# 2) Validate required parameters
# ───────────────────────────────────────────────────────────────────────────────
if [[ -z "$src" ]]; then
  echo "Error: --source is required." >&2; exit 1
fi
if [[ -z "$dst" ]]; then
  echo "Error: --target is required." >&2; exit 1
fi
if [[ ! -e "$src" ]]; then
  echo "Error: Source '$src' does not exist." >&2; exit 1
fi

# ───────────────────────────────────────────────────────────────────────────────
# 3) Ensure rsync is installed
# ───────────────────────────────────────────────────────────────────────────────
if ! command -v rsync &>/dev/null; then
  echo "Error: 'rsync' not found. Install with 'sudo pacman -S rsync'." >&2
  exit 1
fi

# ───────────────────────────────────────────────────────────────────────────────
# 4) Build rsync options
# ───────────────────────────────────────────────────────────────────────────────
# -a : archive (recursive, preserves perms, etc.)
# -h : human-readable numbers
# --info=progress2 : overall progress + per-file stats
# --stats : summary at end
rsync_opts=( -ah --info=progress2 --stats )

# ───────────────────────────────────────────────────────────────────────────────
# 5) Execute copy
# ───────────────────────────────────────────────────────────────────────────────
if [[ -f "$src" ]]; then
  # Single file
  parent_dir=$(dirname "$dst")
  mkdir -p "$parent_dir"
  printf "Copying file:\n  %s → %s\n\n" "$src" "$dst"
  rsync "${rsync_opts[@]}" "$src" "$dst"

elif [[ -d "$src" ]]; then
  # Directory
  if [[ "$recursive" != true ]]; then
    echo "Error: '$src' is a directory; add -r to copy recursively." >&2
    exit 1
  fi
  # Determine destination folder
  if [[ -d "$dst" ]]; then
    dst="${dst%/}/$(basename "$src")"
  fi
  mkdir -p "$dst"
  printf "Recursively copying directory:\n  %s → %s\n\n" "$src" "$dst"
  # Trailing slashes: copy CONTENTS of src into dst
  rsync "${rsync_opts[@]}" "${src%/}/" "${dst%/}/"

else
  echo "Error: '$src' is neither a file nor a directory." >&2
  exit 1
fi

echo -e "\nDone."
exit 0

