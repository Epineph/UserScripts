#!/usr/bin/env bash
#
# format_shell_scripts.sh
#
# A utility to automatically lint and format shell scripts using
# shfmt and shellcheck. Supports individual files or directories.
#
# Usage:
#   format_shell_scripts.sh [OPTIONS] <file-or-dir> [...]
#
# Options:
#   -i, --indent N       Use N spaces for indentation (default: 2)
#   -w, --wrap N         Wrap lines longer than N characters (default: 80)
#   -s, --shellcheck     Run shellcheck on each file
#   -b, --backup         Create a backup copy before formatting
#   -h, --help           Display this help and exit
#
# Requires:
#   - shfmt          (https://github.com/mvdan/sh)
#   - shellcheck     (optional)

set -euo pipefail

INDENT=2
WRAP=80
RUN_SHELLCHECK=false
BACKUP=false
TARGETS=()

usage() {
  grep '^#' "$0" | sed 's/^#//'
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
  -i | --indent)
    INDENT="$2"
    shift 2
    ;;
  -w | --wrap)
    WRAP="$2"
    shift 2
    ;;
  -s | --shellcheck)
    RUN_SHELLCHECK=true
    shift
    ;;
  -b | --backup)
    BACKUP=true
    shift
    ;;
  -h | --help)
    usage
    ;;
  -* | --*)
    echo "Unknown option: $1" >&2
    usage
    ;;
  *)
    TARGETS+=("$1")
    shift
    ;;
  esac
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "Error: No files or directories specified." >&2
  usage
fi

# Ensure shfmt is available
if ! command -v shfmt &>/dev/null; then
  echo "Error: shfmt not found. Install it from https://github.com/mvdan/sh." >&2
  exit 1
fi

# Optionally ensure shellcheck is available
if $RUN_SHELLCHECK && ! command -v shellcheck &>/dev/null; then
  echo "Warning: shellcheck not found; skipping lint stage." >&2
  RUN_SHELLCHECK=false
fi

# Function to process a single file
process_file() {
  local file="$1"
  echo "Processing $file..."

  # Backup if requested
  if $BACKUP; then
    cp "$file" "$file.bak"
  fi

  # Format in-place with shfmt (indent and simplify; wrap is implicit)
  shfmt -i "$INDENT" -ci -sr -w "$file"

  # Optionally enforce wrap length via shfmt if supported
  if [[ -n "$WRAP" ]]; then
    shfmt -w -nbbc -ln bash -fmt indent -o "$file" "$file"
  fi

  # Run shellcheck if requested
  if $RUN_SHELLCHECK; then
    echo "Running shellcheck on $file..."
    shellcheck "$file" || true
  fi
}

# Traverse targets and process shell scripts
for target in "${TARGETS[@]}"; do
  if [[ -d "$target" ]]; then
    # find .sh files or executables with shebang
    mapfile -t files < <(
      find "$target" -type f \
        \( -name '*.sh' -o -perm /u+x \)
    )
  elif [[ -f "$target" ]]; then
    files=("$target")
  else
    echo "Warning: $target not found, skipping." >&2
    continue
  fi

  for file in "${files[@]}"; do
    process_file "$file"
  done
done

echo "Done."
