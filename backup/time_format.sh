#!/usr/bin/env bash
#
# Name: timeformat.sh
# Description: Summarize input time (seconds, minutes, hours) and display it in a
#              human-readable format, omitting zero components.
# Version: 1.0
# Author: ChatGPT
#
# Help Section:
print_help() {
    cat << EOF
Usage: timeformat.sh [options]

This script takes time durations as inputs in seconds, minutes, or hours
(you can mix them), then sums them and prints the total in a human-readable
format (omitting 0-value components).

Options:
  -s, -S, --seconds <n>   Add <n> seconds to total time
  -m, -M, --minutes <n>   Add <n> minutes to total time
  -H, --hours <n>         Add <n> hours   to total time
  -h, --help              Show this help message and exit

Examples:
  1) timeformat.sh -s 45
     -> "45 seconds"

  2) timeformat.sh -m 1
     -> "1 minute"

  3) timeformat.sh -m 1 -s 10
     -> "1 minute and 10 seconds"

  4) timeformat.sh -H 1 -m 10
     -> "1 hour and 10 minutes"

  5) timeformat.sh -H 1 -m 10 -s 0
     -> "1 hour and 10 minutes"   (no redundant "0 seconds")

EOF
}

########################################
# Parse command-line arguments
########################################
total_seconds=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|-S|--seconds)
            shift
            [[ "$1" =~ ^[0-9]+$ ]] || { echo "Error: --seconds requires an integer argument."; exit 1; }
            total_seconds=$(( total_seconds + $1 ))
            ;;
        -m|-M|--minutes)
            shift
            [[ "$1" =~ ^[0-9]+$ ]] || { echo "Error: --minutes requires an integer argument."; exit 1; }
            total_seconds=$(( total_seconds + $1 * 60 ))
            ;;
        -H|--hours)
            shift
            [[ "$1" =~ ^[0-9]+$ ]] || { echo "Error: --hours requires an integer argument."; exit 1; }
            total_seconds=$(( total_seconds + $1 * 3600 ))
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            echo "Unrecognized argument: $1"
            echo "Try '$0 --help' for more information."
            exit 1
            ;;
    esac
    shift
done

########################################
# Compute final hours, minutes, seconds
########################################
hours=$(( total_seconds / 3600 ))
remain=$(( total_seconds % 3600 ))
minutes=$(( remain / 60 ))
seconds=$(( remain % 60 ))

########################################
# Build readable output
########################################
parts=()

if (( hours > 0 )); then
    if (( hours == 1 )); then
        parts+=("1 hour")
    else
        parts+=("$hours hours")
    fi
fi

if (( minutes > 0 )); then
    if (( minutes == 1 )); then
        parts+=("1 minute")
    else
        parts+=("$minutes minutes")
    fi
fi

if (( seconds > 0 )); then
    if (( seconds == 1 )); then
        parts+=("1 second")
    else
        parts+=("$seconds seconds")
    fi
fi

# If everything is zero, just print "0 seconds"
if [[ ${#parts[@]} -eq 0 ]]; then
    echo "0 seconds"
    exit 0
fi

# Join the parts with commas and an "and" before the last entry
# For example: "1 hour, 10 minutes, and 5 seconds"
if [[ ${#parts[@]} -eq 1 ]]; then
    # Only one component
    echo "${parts[0]}"
elif [[ ${#parts[@]} -eq 2 ]]; then
    # Two components
    echo "${parts[0]} and ${parts[1]}"
else
    # Three (or more) components
    # (Normally we will have at most 3 here: hours, minutes, seconds)
    echo "${parts[@]::${#parts[@]}-1} and ${parts[-1]}" | \
        sed 's/ /, /g;s/,$/ /;s/, $/ /'
    # Above sed usage is a bit contrived; easier is manual approach:
    # echo "${parts[0]}, ${parts[1]}, and ${parts[2]}"
fi

