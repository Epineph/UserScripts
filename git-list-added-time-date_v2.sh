#!/usr/bin/env bash
#
# git-list-added.sh – List files with the date they were first added to the Git repo
# Enhanced: pretty date formatting, limit results, optional color, parentheses ISO, and export to CSV/PDF
#
# SYNOPSIS
#   git-list-added.sh [OPTIONS] [PATH...]
#
# OPTIONS
#   -h, --help           display this help and exit
#   -r, --reverse        sort in reverse order (newest additions first)
#   -n, --number N       limit output to the first N results
#   -c, --color          colorize terminal output (requires ANSI-capable terminal)
#   -p, --paren          append ISO timestamp in parentheses after pretty date
#   -e, --export FORMAT  export output; FORMAT = csv or pdf
#
set -euo pipefail

# Default settings
REVERSE_SORT=0
LIMIT=0
COLOR=0
PAREN=0
EXPORT=""
PATHS=()

# Show help text
show_help() {
    cat <<-EOF
Usage: $0 [OPTIONS] [PATH...]

Options:
  -h, --help           Show this help and exit
  -r, --reverse        Sort newest additions first
  -n, --number N       Limit output to the first N results
  -c, --color          Colorize terminal output
  -p, --paren          Append original ISO timestamp in parentheses
  -e, --export FORMAT  Export to "csv" or "pdf" (requires pandoc)
EOF
}

# Compute ordinal suffix for day
ordinal() {
    local d=$1 mod100=$((d % 100))
    if (( mod100 >= 11 && mod100 <= 13 )); then
        echo th
    else
        case $((d % 10)) in
            1) echo st ;; 2) echo nd ;; 3) echo rd ;;
            *) echo th ;;
        esac
    fi
}

# Convert ISO 8601 to human-readable
pretty_date() {
    local iso=$1
    local re='^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})([+-][0-9]{2}):([0-9]{2})$'
    if [[ $iso =~ $re ]]; then
        local y=${BASH_REMATCH[1]} m=${BASH_REMATCH[2]} d=${BASH_REMATCH[3]}
        local H=${BASH_REMATCH[4]} M=${BASH_REMATCH[5]} S=${BASH_REMATCH[6]}
        local off_h=${BASH_REMATCH[7]} off_m=${BASH_REMATCH[8]}
        printf "%s UTC%s%s on %s, %d%s of %s %d" \
            "${H}:${M}:${S}" "${off_h}" "${off_m}" \
            "$(date -d "${y}-${m}-${d}T${H}:${M}:${S}${off_h}:${off_m}" +%A)" \
            "$((10#${d}))" "$(ordinal $((10#${d})))" \
            "$(date -d "${y}-${m}-${d}" +%B)" "$y"
    else
        echo "$iso"
    fi
}

# Parse options
while (( $# )); do
    case "$1" in
        -h|--help)      show_help; exit 0 ;;  
        -r|--reverse)   REVERSE_SORT=1; shift ;;  
        -n|--number)    LIMIT=$2; shift 2 ;;  
        -c|--color)     COLOR=1; shift ;;  
        -p|--paren)     PAREN=1; shift ;;  
        -e|--export)    EXPORT=$2; shift 2 ;;  
        --)             shift; break ;;  
        -*)             echo "Unknown option: $1" >&2; exit 1 ;;
        *)              PATHS+=("$1"); shift ;;  
    esac
done

# Default path
(( ${#PATHS[@]} == 0 )) && PATHS=(.)
# Verify Git repo
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Error: not a Git working tree." >&2; exit 1
fi

# Prepare color codes
if (( COLOR )); then
    YEL=$(tput setaf 3) ; GRE=$(tput setaf 2) ; RES=$(tput sgr0)
else
    YEL=""; GRE=""; RES=""
fi

# Export to CSV
if [[ $EXPORT == "csv" ]]; then
    out=git-list-added.csv
    echo "time,date,timezone,script" > "$out"
    git ls-files -- "${PATHS[@]}" | \
    while IFS= read -r file; do
        iso=$(git log --diff-filter=A --format='%cI' -- "$file" | tail -n1)
        [[ -z $iso ]] && continue
        if [[ $iso =~ ([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})([+-][0-9]{2})([0-9]{2}) ]]; then
            y=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}; d=${BASH_REMATCH[3]}
            H=${BASH_REMATCH[4]}; M=${BASH_REMATCH[5]}; S=${BASH_REMATCH[6]}
            tz="${BASH_REMATCH[7]}${BASH_REMATCH[8]}"
            echo "${H}:${M}:${S},${y}-${m}-${d},${tz},${file}"
        fi
    done | sort -t, -k1,1$((REVERSE_SORT?"r":"")) | { ((LIMIT>0)) && head -n $LIMIT || cat; } >> "$out"
    echo "CSV exported to $out"
    exit 0
fi

# Export to PDF
if [[ $EXPORT == "pdf" ]]; then
    if ! command -v pandoc &>/dev/null; then
        echo "Error: pandoc is required for PDF export." >&2; exit 1
    fi
    tmp=$(mktemp --suffix=.csv)
    echo "time,date,timezone,script" > "$tmp"
    git ls-files -- "${PATHS[@]}" | \
    while IFS= read -r file; do
        iso=$(git log --diff-filter=A --format='%cI' -- "$file" | tail -n1)
        [[ -z $iso ]] && continue
        if [[ $iso =~ ([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})([+-][0-9]{2})([0-9]{2}) ]]; then
            y=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}; d=${BASH_REMATCH[3]}
            H=${BASH_REMATCH[4]}; M=${BASH_REMATCH[5]}; S=${BASH_REMATCH[6]}
            tz="${BASH_REMATCH[7]}${BASH_REMATCH[8]}"
            echo "${H}:${M}:${S},${y}-${m}-${d},${tz},${file}" >> "$tmp"
        fi
    done
    # Apply sort & limit then overwrite tmp
    sorted=$(mktemp --suffix=.csv)
    sort -t, -k1,1$((REVERSE_SORT?"r":"")) "$tmp" | { ((LIMIT>0)) && head -n $LIMIT || cat; } > "$sorted"
    mv "$sorted" "$tmp"
    pandoc --from=csv --to=pdf "$tmp" -o git-list-added.pdf
    echo "PDF exported to git-list-added.pdf"
    exit 0
fi

# Default terminal output
{
    git ls-files -- "${PATHS[@]}" |
    while IFS= read -r file; do
        iso=$(git log --diff-filter=A --format='%cI' -- "$file" | tail -n1)
        [[ -z $iso ]] && continue
        pretty=$(pretty_date "$iso")
        disp="$pretty"
        (( PAREN )) && disp+=" (${iso})"
        if (( COLOR )); then
            printf "%s%s%s\t%s%s%s\n" "$YEL" "$disp" "$RES" "$GRE" "$file" "$RES"
        else
            printf "%s\t%s\n" "$disp" "$file"
        fi
    done
} | sort -t$'\t' -k1,1$((REVERSE_SORT?"r":"")) \
  | { ((LIMIT>0)) && head -n $LIMIT || cat; } \
  | column -ts $'\t' -o '   '

exit 0

