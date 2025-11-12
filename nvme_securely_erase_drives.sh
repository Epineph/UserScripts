#!/usr/bin/env bash
###############################################################################
# NVMe Secure Erase Script
#
# This script securely erases entire NVMe drives using the built-in NVMe
# format command with secure erase mode. It accepts a list of drives as arguments,
# as well as options for verbosity and force suppression of warnings.
#
# Usage:
#   sudo ./nvme_secure_erase.sh -d /dev/nvme1n1 /dev/nvme0n1 [-v] [-f]
#
# Options:
#   -d, --drive      One or more NVMe drive devices (required).
#   -v, --verbose    Enable verbose output.
#   -f, --force      Skip confirmation prompts and force erase (adds --force
#                    to the nvme format command to suppress warnings).
#
# CAUTION: This script will irreversibly erase all data on the specified drives.
###############################################################################

set -e  # Exit immediately if a command exits with a non-zero status.

# Function to show usage help
usage() {
    echo "Usage: $0 -d <drive1> [drive2 ...] [-v|--verbose] [-f|--force]"
    exit 1
}

# Parse command-line options using getopt
OPTIONS=$(getopt -o d:vf --long drive:,verbose,force -n "$0" -- "$@")
if [ $? -ne 0 ]; then
    usage
fi
eval set -- "$OPTIONS"

# Initialize variables
DRIVES=()
VERBOSE=0
FORCE=0

# Process the options
while true; do
    case "$1" in
        -d|--drive)
            shift
            # Allow one or more drives until the next option is found.
            while [[ "$1" != "--" && "$1" != "" && "$1" != -* ]]; do
                DRIVES+=("$1")
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

# If no drives specified, show help text.
if [ ${#DRIVES[@]} -eq 0 ]; then
    echo "Error: No drives specified!"
    usage
fi

# Process each target drive
for DRIVE in "${DRIVES[@]}"; do
    if [ $VERBOSE -eq 1 ]; then
        echo "Inspecting drive: $DRIVE"
        nvme id-ctrl "$DRIVE"
    fi

    # Unless forced, ask for confirmation
    if [ $FORCE -ne 1 ]; then
        read -p "Are you sure you want to securely erase $DRIVE? Type 'yes' to proceed: " CONFIRM
        if [ "$CONFIRM" != "yes" ]; then
            echo "Skipping $DRIVE."
            continue
        fi
    fi

    if [ $VERBOSE -eq 1 ]; then
        echo "Securely erasing $DRIVE..."
    fi

    # Execute the secure erase; add --force if forced mode is enabled.
    if [ $FORCE -eq 1 ]; then
        sudo nvme format "$DRIVE" --ses=1 --force
    else
        sudo nvme format "$DRIVE" --ses=1
    fi

    if [ $VERBOSE -eq 1 ]; then
        echo "$DRIVE has been securely erased."
    fi
done

if [ $VERBOSE -eq 1 ]; then
    echo "All specified NVMe drives have been processed."
fi

