#!/usr/bin/env bash
# backup_usb.sh - Recursively compress a USB partition into a .tar.gz archive
#
# Usage: backup_usb.sh [-h|--help] DEVICE
#
# Options:
#   -h, --help    Show this help message and exit.
#
# Arguments:
#   DEVICE        The block device representing the USB partition (e.g., /dev/sda4).
#
# Description:
#   This script mounts the specified USB partition to a temporary directory,
#   creates a compressed tar.gz archive of its entire contents, saves the archive
#   to $HOME/Documents, and then unmounts and removes the temporary directory.

set -euo pipefail

# Function: print_help
# Prints the help message (first 20 lines of this script).
print_help() {
    sed -n '1,20p' "$0"
}

# Parse arguments
if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
    print_help
    exit 0
fi

if [[ $# -ne 1 ]]; then
    echo "Error: Exactly one argument expected." >&2
    print_help
    exit 1
fi

DEVICE="$1"

# Check if running as root (required for mounting)
if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: This script must be run as root." >&2
    exit 1
fi

# Verify that the device exists and is a block device
if [[ ! -b "$DEVICE" ]]; then
    echo "Error: Device $DEVICE does not exist or is not a block device." >&2
    exit 1
fi

# Derive partition name (e.g., sda4) and output paths
PART_NAME="$(basename "$DEVICE")"
OUTPUT_DIR="$HOME/Documents"
OUTPUT_FILE="${OUTPUT_DIR}/${PART_NAME}.tar.gz"

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Create a temporary mount point
MOUNT_POINT="$(mktemp -d /mnt/backup_usb.XXXXXX)"

# Ensure cleanup: unmount and remove mount point on exit
cleanup() {
    if mountpoint -q "$MOUNT_POINT"; then
        umount "$MOUNT_POINT"
    fi
    rmdir "$MOUNT_POINT"
}
trap cleanup EXIT

# Mount the device read-only to prevent changes
mount -o ro "$DEVICE" "$MOUNT_POINT"

# Archive and compress recursively
echo "Creating archive: $OUTPUT_FILE"
tar -czf "$OUTPUT_FILE" -C "$MOUNT_POINT" .

echo "Backup of $DEVICE completed successfully: $OUTPUT_FILE"

