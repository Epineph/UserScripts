#!/usr/bin/env bash
###############################################################################
# Random Overwrite Script Using pv and dd
#
# This optional script overwrites entire devices with random data from
# /dev/urandom. It uses pv to display a progress bar (with ETA and percentage)
# and dd to perform the write. Although some users choose this approach to “scrub”
# data, for modern NVMe SSDs a secure erase (using nvme format) is usually more
# effective and less stressful for the drive.
#
# Usage:
#   sudo ./random_overwrite.sh -d /dev/nvme1n1 [ /dev/nvme0n1 ... ] [-v]
#
# Options:
#   -d, --drive      One or more target drive devices (required).
#   -v, --verbose    Enable verbose output.
#
# CAUTION: This script writes over the entire device using random data,
#          which can be extremely time-consuming and may significantly wear out
#          SSDs.
###############################################################################

set -e

# Function to show usage help
usage() {
    echo "Usage: $0 -d <device1> [device2 ...] [-v|--verbose]"
    exit 1
}

# Parse command-line options using getopt
OPTIONS=$(getopt -o d:v --long drive:,verbose -n "$0" -- "$@")
if [ $? -ne 0 ]; then
    usage
fi
eval set -- "$OPTIONS"

# Initialize variables
DEVICES=()
VERBOSE=0

# Process options
while true; do
    case "$1" in
        -d|--drive)
            shift
            # Collect one or more device names.
            while [[ "$1" != "--" && "$1" != "" && "$1" != -* ]]; do
                DEVICES+=("$1")
                shift
            done
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# If no devices specified, show help text.
if [ ${#DEVICES[@]} -eq 0 ]; then
    echo "Error: No devices specified!"
    usage
fi

# Process each target device
for DEVICE in "${DEVICES[@]}"; do
    # Determine device size in bytes.
    SIZE=$(sudo blockdev --getsize64 "$DEVICE")
    if [ $VERBOSE -eq 1 ]; then
        echo "Overwriting $DEVICE (Size: $SIZE bytes) with random data..."
    fi

    # Use pv to provide progress information.
    # pv's -s option sets the total size so that it can display ETA and percentage.
    sudo sh -c "pv -s $SIZE < /dev/urandom | dd of=$DEVICE bs=1M status=none"

    if [ $VERBOSE -eq 1 ]; then
        echo "$DEVICE has been overwritten with random data."
    fi
done

if [ $VERBOSE -eq 1 ]; then
    echo "Random overwrite completed for all specified devices."
fi
