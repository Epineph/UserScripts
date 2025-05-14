#!/usr/bin/env bash
###############################################################################
# blkdiscard Partition Wipe Script
#
# This script clears NVMe partitions by invoking the blkdiscard command, which
# issues a TRIM/discard command to the drive. It accepts one or more partitions,
# with options for verbose output and forced operation.
#
# Usage:
#   sudo ./blkdiscard_wipe.sh -p /dev/nvme1n1p1 /dev/nvme1n1p2 [-v] [-f]
#
# Options:
#   -p, --partition  One or more partition devices (required).
#   -v, --verbose    Enable verbose output.
#   -f, --force      Skip confirmation prompts.
#
# CAUTION: This operation will irreversibly discard all data on the specified
#          partitions.
###############################################################################

set -e

# Function to show usage help
usage() {
    echo "Usage: $0 -p <partition1> [partition2 ...] [-v|--verbose] [-f|--force]"
    exit 1
}

# Parse command-line options using getopt
OPTIONS=$(getopt -o p:vf --long partition:,verbose,force -n "$0" -- "$@")
if [ $? -ne 0 ]; then
    usage
fi
eval set -- "$OPTIONS"

# Initialize variables
PARTITIONS=()
VERBOSE=0
FORCE=0

# Process options
while true; do
    case "$1" in
        -p|--partition)
            shift
            # Collect one or more partitions until the next option is encountered.
            while [[ "$1" != "--" && "$1" != "" && "$1" != -* ]]; do
                PARTITIONS+=("$1")
                shift
            done
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -f|--force)
            FORCE=1
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

# If no partitions were specified, show help text.
if [ ${#PARTITIONS[@]} -eq 0 ]; then
    echo "Error: No partitions specified!"
    usage
fi

# Process each partition
for PART in "${PARTITIONS[@]}"; do
    if [ $VERBOSE -eq 1 ]; then
        echo "Preparing to discard data on partition: $PART"
    fi

    # Unless in forced mode, prompt for confirmation.
    if [ $FORCE -ne 1 ]; then
        read -p "Are you sure you want to discard data on $PART? Type 'yes' to proceed: " CONFIRM
        if [ "$CONFIRM" != "yes" ]; then
            echo "Skipping $PART."
            continue
        fi
    fi

    sudo blkdiscard "$PART"
    if [ $VERBOSE -eq 1 ]; then
        echo "$PART has been discarded."
    fi
done

if [ $VERBOSE -eq 1 ]; then
    echo "All specified partitions have been processed."
fi

