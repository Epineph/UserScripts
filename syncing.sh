#!/bin/bash

# Initial variables
source=""
destination=""
rsync_opts="-ar" # default rsync options
filter_mode="" # include or exclude
filter_type="" # file or dir
pattern="" # pattern for filtering

# Function to print usage
usage() {
    echo "Usage: $0 -s|--source SOURCE -d|--destination DESTINATION [OPTIONS]"
    echo "Options:"
    echo "  -f, --filter                Enable filtering mode (requires -[i/e]sp)"
    echo "  -itf, --include-type-file   Include files matching pattern"
    echo "  -etf, --exclude-type-file   Exclude files matching pattern"
    echo "  -itd, --include-type-dir    Include dirs matching pattern"
    echo "  -etd, --exclude-type-dir    Exclude dirs matching pattern"
    echo "  -isp, --include-pattern     Include pattern"
    echo "  -esp, --exclude-pattern     Exclude pattern"
    exit 1
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -s|--source) source="$2"; shift ;;
        -d|--destination) destination="$2"; shift ;;
        -f|--filter) filter_mode="true" ;;
        -itf|--include-type-file) filter_type="file"; pattern="$2"; shift ;;
        -etf|--exclude-type-file) filter_type="-not -type f"; pattern="$2"; shift ;;
        -itd|--include-type-dir) filter_type="dir"; pattern="$2"; shift ;;
        -etd|--exclude-type-dir) filter_type="-not -type d"; pattern="$2"; shift ;;
        -isp|--include-pattern) pattern="$2"; shift ;;
        -esp|--exclude-pattern) pattern="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; usage; exit 1 ;;
    esac
    shift
done

# Check mandatory inputs
if [ -z "$source" ] || [ -z "$destination" ]; then
    echo "Source and destination are mandatory."
    usage
    exit 1
fi

# Check if source is a directory
if [ ! -d "$source" ]; then
    echo "Source is not a directory."
    exit 1
fi

# Check if destination exists, if not prompt to create
if [ ! -d "$destination" ]; then
    read -p "Destination does not exist. Create it? (y/n) " answer
    if [ "$answer" = "y" ]; then
        mkdir -p "$destination"
    else
        echo "Exiting."
        exit 1
    fi
fi

# Handling filtering
if [ "$filter_mode" = "true" ]; then
    echo "Filtering is enabled, but this functionality needs to be expanded based on specific requirements."
    # Implement the specific filtering logic here
else
    # Default rsync execution without filter
    rsync $rsync_opts "$source/" "$destination/"
fi