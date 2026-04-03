#!/usr/bin/env bash
#
# git-list-added.sh – List files with the date they were first added to the Git repo
# Enhanced version: pretty date formatting, limit number of results, and optional colorized output
#
# SYNOPSIS
#   git-list-added.sh [OPTIONS] [PATH...]
#
# OPTIONS
#   -h, --help       display this help and exit
#   -r, --reverse    sort in reverse order (newest additions first)
#   -n, --number N   limit output to the first N results
#   -c, --color      colorize the output (requires terminal support)
#
# DESCRIPTION
#   For each file under version control (in the specified PATHs, or . by default),
#   show the date of the commit in which it was introduced, formatted as:
#     HH:MM:SS UTC±ZZZZ on Weekday, D<suffix> of Month YYYY
#   e.g. 16:49:26 UTC+0200 on Sunday, 15th of June 2025
#
set -euo pipefail

# Default values
REVERSE_SORT=0
LIMIT=0
COLOR=0
PATHS=()

# Help text function
show_help() {
    cat <<-EOF
Usage: $0 [OPTIONS] [PATH...]

Options:
  -h, --help         Show this help and exit
  -r, --reverse      Sort newest additions first
  -n, --number N     Limit output to the first N results
  -c, --color        Colorize output (requires ANSI-capable terminal)
EOF
}

# Function to compute ordinal suffix for a day number
ordinal() {
    local d=$1
    local mod100=$((d % 100))
    if (( mod100 >= 11 && mod100 <= 13 )); then
        echo th
    else
        case $((d % 10)) in
            1) echo st ;; 2) echo nd ;; 3) echo rd ;;
            *) echo th ;;
        esac
    fi
}

# Function to convert ISO 8601 datetime to human-readable format
pretty_date() {
    local iso="$1"
    # Regex to capture YYYY-MM-DDTHH:MM:SS±HH:MM
    local re='^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})([+-][0-9]{2}):([0-9]{2})$'
    if [[ $iso =~ $re ]]; then
        local y=${BASH_REMATCH[1]} m=${BASH_REMATCH[2]} d=${BASH_REMATCH[3]}
        local H=${BASH_REMATCH[4]} M=${BASH_REMATCH[5]} S=${BASH_REMATCH[6]}
        local off_h=${BASH_REMATCH[7]} off_m=${BASH_REMATCH[8]}
        # Use date for localization and week-day names
        printf "%s UTC%s%s on %s, %d%s of %s %d" \
            "${H}:${M}:${S}" "${off_h}" "${off_m}" \
            "$(date -d "${y}-${m}-${d}T${H}:${M}:${S}${off_h}:${off_m}" +%A)" \
            "$((10#${d}))" "$(ordinal $((10#${d})))" \
            "$(date -d "${y}-${m}-${d}" +%B)" "$y"
    else
        # Fallback: print original
        echo "$iso"
    fi
}

# Parse command-line options
while (( $# )); do
    case "$1" in
        -h|--help)
            show_help; exit 0
            ;;
        -r|--reverse)
            REVERSE_SORT=1; shift
            ;;
        -n|--number)
            LIMIT=$2; shift 2
            ;;
        -c|--color)
            COLOR=1; shift
            ;;
        --)
            shift; break
            ;;
        -*)
            echo "Unknown option: $1" >&2; exit 1
            ;;
        *)
            PATHS+=("$1"); shift
            ;;
    esac
done

# Default to current directory if no paths given
if [ ${#PATHS[@]} -eq 0 ]; then
    PATHS=(.)
fi

# Ensure inside a Git repository
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Error: not inside a Git working tree." >&2
    exit 1
fi

# Setup color codes
if (( COLOR )); then
    YELLOW=$(tput setaf 3)
    GREEN=$(tput setaf 2)
    RESET=$(tput sgr0)
else
    YELLOW=""; GREEN=""; RESET=""
fi

# Main: list files, compute pretty date, and format output
{
    git ls-files -- "${PATHS[@]}" |
    while IFS= read -r file; do
        # Get ISO date of first addition
        iso_date=$(git log --diff-filter=A --format='%cI' -- "$file" | tail -n1)
        [[ -z "$iso_date" ]] && continue
        # Convert to human-friendly format
        pretty=$(pretty_date "$iso_date")
        # Print date and path
        printf '%s	%s
' "$pretty" "$file"
    done
} | sort -t$'\t' -k1,1$( (( REVERSE_SORT )) && echo r ) \
  | { (( LIMIT > 0 )) && head -n "$LIMIT" || cat; }

exit 0

