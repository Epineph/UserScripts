#!/usr/bin/env bash
#
# Script: find_latest.sh
# Description: Recursively find files and sort them by last modification time, using `fd` if available.
#
# Usage:
#   find_latest.sh [-n NUM] [DIRECTORY]
#
# Options:
#   -n NUM   Number of latest files to display (default: 1)
#   -h       Show this help message and exit
#
# Requirements:
#   - fd (version >= 8.4 for --sort support)
#   - bash, stat, sort (fallback if --sort is unavailable)
#
# Author: Epinephrine
#

show_help() {
  grep '^#' "$0" | sed -e 's/^#//' -e 's/^ //'
}

# Default parameters
NUM=1
DIR='.'

# Parse options
while getopts ":n:h" opt; do
  case ${opt} in
    n ) NUM=$OPTARG ;;
    h ) show_help ; exit 0 ;;
    \? ) echo "Invalid option: -$OPTARG" >&2; show_help; exit 1 ;;
    : ) echo "Option -$OPTARG requires an argument." >&2; show_help; exit 1 ;;
  esac
done
shift $((OPTIND -1))

# If a directory argument is provided, use it
if [ $# -gt 0 ]; then
  DIR=$1
fi

# Check if fd supports --sort
if fd --help 2>&1 | grep -q "--sort"; then
  # Use fd built-in sorting by modification time
  fd --type f --sort modified --reverse . "$DIR" | head -n "$NUM"
else
  # Fallback: use stat and sort
  # %Y: modification time as seconds since epoch, \t, then path
  fd --type f . "$DIR" -x stat --printf '%Y\t%n\n' 2>/dev/null \
    | sort -nr \
    | head -n "$NUM" \
    | cut -f2-
fi

