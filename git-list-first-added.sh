#!/usr/bin/env bash
#
# git-list-first-added.sh
#
# Lists every file in the current Git repo together with the
# date it was first introduced (the commit date of the 'A'dd action).
#
# Usage:
#   git-list-first-added.sh [OPTIONS]
#
# Options:
#   -h, --help        Show this help message and exit
#   -r, --reverse     Sort oldest→newest (default is newest→oldest)
#   -f, --format STR  Pass a git‐date(1) format string (default: %ci)
#
# Example:
#   ./git-list-first-added.sh --reverse
#
# How it works:
# 1. `git ls-files` lists every file under version control.
# 2. For each file, `git log --diff-filter=A --pretty=format:"$FMT" -- "$f"` prints
#    only the commit date(s) where the file was added; we take the last (oldest).
# 3. We collect “date<tab>path” pairs, then sort them.
#

set -euo pipefail

# Default settings
SORT_ORDER="--reverse"          # by default, show newest→oldest
DATE_FMT="%ci"                  # ISO-style date
SHOW_HELP=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--reverse)
      SORT_ORDER="";;            # omit --reverse for oldest→newest
    -f|--format)
      shift
      DATE_FMT="$1";;
    -h|--help)
      SHOW_HELP=1;;
    *)
      echo "Unknown option: $1" >&2
      SHOW_HELP=1;;
  esac
  shift
done

if (( SHOW_HELP )); then
  sed -n '2,20p' "$0"
  exit 0
fi

# Ensure we are inside a Git repo
if ! git rev-parse --git-dir &>/dev/null; then
  echo "Error: not a Git repository." >&2
  exit 1
fi

# Main loop: for each tracked file, find its 'A'dd commit date
git ls-files -z \
| while IFS= read -r -d '' file; do
    # --diff-filter=A selects only the commits that Added the file
    # --pretty=format:"$DATE_FMT" prints the date in the chosen format
    first_date=$(git log --diff-filter=A \
                         --pretty=format:"$DATE_FMT" \
                         -- "$file" \
                 | tail -1)

    # If somehow no ’A’ commit was found, you can skip or annotate specially
    if [[ -z "$first_date" ]]; then
      first_date="(no add-commit found)"
    fi

    printf '%s\t%s\n' "$first_date" "$file"
  done \
| sort $SORT_ORDER

exit 0

