#!/usr/bin/env bash

#############################################################################
##
## ll_wrapper - A custom directory listing script with filtering, sorting,
## and export options.
##
## Dependencies:
##   - lsd         (for enhanced tree view)
##   - fd          (for file filtering)
##   - bat         (for help output)
##   - tree, ImageMagick (for export options: png)
##   - csvkit      (optional, for CSV export formatting)
##
## Usage:
##   ll_wrapper [OPTIONS] <directory>
##
## Options:
##   -d, --depth <N>            Set max depth (default: unlimited).
##   -r, --recursive            Enable recursive search.
##   -x, --extensions <EXTS>    Filter by file extensions (comma-separated).
##   -o, --output <format>      Export format: csv, png, html.
##   --sort-by <mode>           Sort files by timestamp.
##                              Allowed modes: git, local, both.
##   -h, --help                 Show this help message.
##
## Examples:
##   ll_wrapper -d 2 -x "sh,py" .
##   ll_wrapper -r -x "md,txt" -o csv ~/projects
##   ll_wrapper --sort-by both .
#############################################################################

# Defaults
DEPTH=""
RECURSIVE=false
EXTENSIONS=""
OUTPUT_FORMAT=""
SORT_MODE=""
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
    --sort-by)
      SORT_MODE="$2"
      shift 2
      ;;
    -h|--help)
      bat --style="grid,header" --paging="never" --color="always" --language="LESS" --theme="Dracula" <<EOF
Usage: $(basename "$0") [OPTIONS] <directory>

Options:
  -d, --depth <N>            Set max depth (default: unlimited).
  -r, --recursive            Enable recursive search.
  -x, --extensions <EXTS>    Filter by file extensions (comma-separated).
  -o, --output <format>      Export format: csv, png, html.
  --sort-by <mode>           Sort files by timestamp. Allowed modes:
                             git    - sort by Git commit time (default if tracked)
                             local  - sort by local modification time
                             both   - show both Git and local times.
  -h, --help                 Show this help message.
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
command -v bat >/dev/null 2>&1 || { echo "Error: 'bat' is not installed."; exit 1; }

# -------------------------
# Build FD Command for File Listing
# -------------------------
FD_CMD=("fd" "--type" "f" "--search-path" "$TARGET_DIR")
[[ -n "$DEPTH" ]] && FD_CMD+=("$DEPTH")
[[ "$RECURSIVE" == true ]] && FD_CMD+=("--hidden")
if [[ -n "$EXTENSIONS" ]]; then
  for ext in $(echo "$EXTENSIONS" | tr ',' ' '); do
    FD_CMD+=("-e" "$ext")
  done
fi

# Generate file list
FILES=()
while IFS= read -r file; do
  FILES+=("$file")
done < <("${FD_CMD[@]}")

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No matching files found in $TARGET_DIR."
  exit 0
fi

# -------------------------
# Function: sort_and_display_files
# -------------------------
sort_and_display_files() {
  # This function sorts files (in the FILES array) based on their timestamps.
  # For each file it retrieves:
  #   - git_time: Unix timestamp of last Git commit (or 0 if not tracked)
  #   - local_time: Local modification time (Unix timestamp)
  # It then sorts in descending order (newest first) and prints the result.
  local tmpfile sorted_entries file local_time git_time sort_key
  tmpfile=$(mktemp)
  for file in "${FILES[@]}"; do
    local_time=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    git_time=$(git log -1 --format=%ct -- "$file" 2>/dev/null || echo 0)
    if [[ "$git_time" -ne 0 ]]; then
      sort_key="$git_time"
    else
      sort_key="$local_time"
    fi
    echo "$sort_key:$git_time:$local_time:$file" >> "$tmpfile"
  done

  # Sort entries descending (newest first) by the first field.
  sorted_entries=$(sort -t: -k1,1nr "$tmpfile")
  rm "$tmpfile"

  if [[ "$SORT_MODE" == "both" ]]; then
    printf "%-25s %-25s %s\n" "Git Commit Date" "Local Mod Date" "File"
    while IFS=: read -r sort_key git_time local_time file; do
      if [[ "$git_time" -ne 0 ]]; then
        git_date=$(date -d @"$git_time" "+%Y-%m-%d %H:%M:%S")
      else
        git_date="N/A"
      fi
      local_date=$(date -d @"$local_time" "+%Y-%m-%d %H:%M:%S")
      printf "%-25s %-25s %s\n" "$git_date" "$local_date" "$file"
    done <<< "$sorted_entries"
  elif [[ "$SORT_MODE" == "local" ]]; then
    printf "%-25s %s\n" "Local Mod Date" "File"
    while IFS=: read -r sort_key git_time local_time file; do
      local_date=$(date -d @"$local_time" "+%Y-%m-%d %H:%M:%S")
      printf "%-25s %s\n" "$local_date" "$file"
    done <<< "$sorted_entries"
  else
    # Default: sort by git (fallback to local if not tracked)
    printf "%-25s %s\n" "Git Commit Date" "File"
    while IFS=: read -r sort_key git_time local_time file; do
      if [[ "$git_time" -ne 0 ]]; then
        git_date=$(date -d @"$git_time" "+%Y-%m-%d %H:%M:%S")
      else
        git_date="N/A"
      fi
      printf "%-25s %s\n" "$git_date" "$file"
    done <<< "$sorted_entries"
  fi
}

# If --sort-by option was provided, display sorted file list and exit.
if [[ -n "$SORT_MODE" ]]; then
  echo "Sorted file list based on '$SORT_MODE' timestamps:"
  sort_and_display_files
  exit 0
fi

# -------------------------
# Display with lsd
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
        echo "\"$file\",$size,\"$mtime\"" >> files_list.csv
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

