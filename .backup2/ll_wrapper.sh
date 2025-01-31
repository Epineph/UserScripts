#!/usr/bin/env bash

###############################################################################
# ll_wrapper - A custom directory listing script with filtering and export options.
#
# Dependencies:
#   - lsd (for enhanced tree view)
#   - fd  (for filtering)
#   - bat (for help output)
#   - tree, csvkit (for export options)
#
# Usage:
#   ll_wrapper [OPTIONS] <directory>
#
# Options:
#   -d, --depth <N>            Set max depth (default: unlimited).
#   -r, --recursive            Enable recursive search.
#   -x, --extensions <EXTS>    Filter by file extensions (comma-separated).
#   -o, --output <format>      Export format: csv, png, html.
#   -h, --help                 Show this help message.
#
# Examples:
#   ll_wrapper -d 2 -x "sh,py" .
#   ll_wrapper -r -x "md,txt" -o csv ~/projects
###############################################################################

# Defaults
DEPTH=""
RECURSIVE=false
EXTENSIONS=""
OUTPUT_FORMAT=""
TARGET_DIR="$PWD"

# -------------------------
# Parse Arguments
# -------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--depth)
      DEPTH="--depth $2"
      shift 2
      ;;
    -r|--recursive)
      RECURSIVE=true
      shift
      ;;
    -x|--extensions)
      EXTENSIONS="$2"
      shift 2
      ;;
    -o|--output)
      OUTPUT_FORMAT="$2"
      shift 2
      ;;
    -h|--help)
      bat --style="grid,header" --paging="never" --color="always" --language="LESS" --theme="Dracula" <<EOF
Usage: ll_wrapper [OPTIONS] <directory>

Options:
  -d, --depth <N>            Set max depth (default: unlimited).
  -r, --recursive            Enable recursive search.
  -x, --extensions <EXTS>    Filter by file extensions (comma-separated).
  -o, --output <format>      Export format: csv, png, html.
  -h, --help                 Show this help message.

Examples:
  ll_wrapper -d 2 -x "sh,py" .
  ll_wrapper -r -x "md,txt" -o csv ~/projects
EOF
      exit 0
      ;;
    *)
      TARGET_DIR="$1"
      shift
      ;;
  esac
done

# -------------------------
# Check Dependencies
# -------------------------
command -v lsd >/dev/null 2>&1 || { echo "Error: 'lsd' is not installed."; exit 1; }
command -v fd  >/dev/null 2>&1 || { echo "Error: 'fd' is not installed."; exit 1; }

# -------------------------
# Build `fd` Filtering
# -------------------------
FD_CMD=("fd" "--type f" "--search-path" "$TARGET_DIR")
[[ -n "$DEPTH" ]] && FD_CMD+=("$DEPTH")
[[ "$RECURSIVE" == true ]] && FD_CMD+=("--hidden")
[[ -n "$EXTENSIONS" ]] && for ext in $(echo "$EXTENSIONS" | tr ',' ' '); do FD_CMD+=("-e" "$ext"); done

# -------------------------
# Generate File List
# -------------------------
FILES=()
while IFS= read -r file; do
  FILES+=("$file")
done < <("${FD_CMD[@]}")

# If no files found
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No matching files found."
  exit 0
fi

# -------------------------
# Display with `lsd`
# -------------------------
lsd --tree "$TARGET_DIR" $DEPTH

# -------------------------
# Export Options
# -------------------------
if [[ -n "$OUTPUT_FORMAT" ]]; then
  case "$OUTPUT_FORMAT" in
    csv)
      echo "Exporting to files_list.csv..."
      printf "File,Size (KB),Modified Time\n" > files_list.csv
      for file in "${FILES[@]}"; do
        size=$(du -k "$file" | cut -f1)
        mtime=$(stat -c %y "$file")
        echo "$file,$size,$mtime" >> files_list.csv
      done
      ;;
    
    png)
      echo "Generating PNG..."
      tree "$TARGET_DIR" --charset=ascii | convert label:@- files_tree.png
      ;;
    
    html)
      echo "Generating HTML..."
      {
        echo "<html><head><title>File Tree</title></head><body><h1>File Tree</h1><ul>"
        for file in "${FILES[@]}"; do
          realpath=$(realpath "$file")
          echo "<li><a href=\"file://$realpath\">$(basename "$file")</a></li>"
        done
        echo "</ul></body></html>"
      } > files_tree.html
      ;;
    
    *)
      echo "Error: Unsupported output format '$OUTPUT_FORMAT'. Use csv, png, or html."
      exit 1
      ;;
  esac
fi

