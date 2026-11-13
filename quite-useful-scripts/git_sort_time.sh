#!/usr/bin/env bash
# sort_by_git_time.sh
#
# This script sorts a list of files based on the timestamp of the last Git commit
# (if available) and shows both the Git commit date and the local modification date.
#
# Usage:
#   ./sort_by_git_time.sh [options] file1 file2 file3 ...
#
# Options:
#   -g, --git      Sort by Git commit time (default).
#   -l, --local    Sort by local modification time.
#   -b, --both     Show both Git commit and local modification dates.
#
# The default is to sort by Git commit time. If a file is not tracked by Git,
# its Git commit time will be reported as "N/A" and its local modification time
# is used as a fallback for sorting.
#
# Example:
#   ./sort_by_git_time.sh -b bat-fd_wrapper bat-fd_wrapper.sh bat_fd_wrapper.sh batwrapper.sh

# Default: sort by git commit time
sort_by="git"
show_both=0

# Parse options
while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--git)
      sort_by="git"
      shift
      ;;
    -l|--local)
      sort_by="local"
      shift
      ;;
    -b|--both)
      show_both=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 [options] file1 file2 ..." >&2
  exit 1
fi

# Declare an array to hold entries formatted as:
# sort_key:git_time:local_time:file
entries=()

for file in "$@"; do
  # Get local modification time (Unix timestamp)
  local_time=$(stat -c %Y "$file" 2>/dev/null || echo 0)
  # Get Git commit time (Unix timestamp) for the file; if not tracked, output 0.
  git_time=$(git log -1 --format=%ct -- "$file" 2>/dev/null || echo 0)
  # Use Git time as primary sort key if available; otherwise, use local time.
  if [[ "$git_time" -ne 0 ]]; then
    sort_key=$git_time
  else
    sort_key=$local_time
  fi
  # Save entry in the array
  entries+=("$sort_key:$git_time:$local_time:$file")
done

# Sort the entries in descending order (newest first) based on the chosen sort key.
# If sorting by Git, then the sort key is the Git commit time (or local time if not tracked).
IFS=$'\n' sorted=($(sort -t: -k1,1nr <<<"${entries[*]}"))
unset IFS

# Print a header.
if [[ $show_both -eq 1 ]]; then
  printf "%-25s %-25s %s\n" "Git Commit Date" "Local Mod Date" "File"
else
  if [[ "$sort_by" == "git" ]]; then
    printf "%-25s %s\n" "Git Commit Date" "File"
  else
    printf "%-25s %s\n" "Local Mod Date" "File"
  fi
fi

# Print each sorted entry.
for entry in "${sorted[@]}"; do
  IFS=":" read -r sort_key git_time local_time file <<< "$entry"
  # Convert timestamps to human-readable dates (if available)
  if [[ "$git_time" -ne 0 ]]; then
    git_date=$(date -d @"$git_time" "+%Y-%m-%d %H:%M:%S")
  else
    git_date="N/A"
  fi
  local_date=$(date -d @"$local_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "N/A")
  if [[ $show_both -eq 1 ]]; then
    printf "%-25s %-25s %s\n" "$git_date" "$local_date" "$file"
  else
    if [[ "$sort_by" == "git" ]]; then
      printf "%-25s %s\n" "$git_date" "$file"
    else
      printf "%-25s %s\n" "$local_date" "$file"
    fi
  fi
done

