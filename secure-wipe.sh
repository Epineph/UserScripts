#!/usr/bin/env python3
# ----------------------------------------------------------------------
# Secure Disk/Partition Erasure Script
# Purpose : Securely wipe partitions or disks beyond recovery
# License : MIT
# ----------------------------------------------------------------------
set -euo pipefail

print_help() {
cat <<EOF
Usage: $(basename "$0") -p|--partitions <partition1> [partition2 ...] 
                        -d|--disks <disk1> [disk2 ...]

Options:
  -p, --partitions    Space-separated list of partitions (e.g. /dev/sda3 /dev/nvme1n1p4)
  -d, --disks         Space-separated list of entire disks (e.g. /dev/sda /dev/nvme1n1)
  -h, --help          Show this help message

Description:
  This script securely erases partitions and disks using:
    - shred (DoD-like overwrite)
    - blkdiscard (TRIM/discard for SSDs, if supported)
    - wipefs (to remove filesystem/LUKS/RAID signatures)
  You must run this script as root.

Examples:
  $(basename "$0") --partitions /dev/sda3 /dev/nvme1n1p4
  $(basename "$0") --disks /dev/sda --partitions /dev/sda2
EOF
}

log() {
    echo -e "\033[1;34m[INFO]\033[0m $*"
}

warn() {
    echo -e "\033[1;33m[WARN]\033[0m $*" >&2
}

fail() {
    echo -e "\033[1;31m[ERROR]\033[0m $*" >&2
    exit 1
}

secure_erase_partition() {
    local part="$1"
    log "Processing partition: $part"

    if mount | grep -q "$part"; then
        fail "Partition $part is mounted. Unmount before proceeding."
    fi

    log "Attempting blkdiscard on $part (if supported)..."
    if blkdiscard "$part" 2>/dev/null; then
        log "blkdiscard succeeded on $part (fast secure erase for SSDs)"
    else
        warn "blkdiscard failed on $part — falling back to shred"
        shred -v -n 3 -z "$part"
    fi

    log "Wiping filesystem and RAID signatures on $part"
    wipefs -a "$part"
}

secure_erase_disk() {
    local disk="$1"
    log "Processing disk: $disk"

    if mount | grep -q "$disk"; then
        fail "Disk $disk or its partitions are mounted. Unmount before proceeding."
    fi

    log "Attempting blkdiscard on $disk..."
    if blkdiscard "$disk" 2>/dev/null; then
        log "blkdiscard succeeded on $disk (ideal for SSDs)"
    else
        warn "blkdiscard failed on $disk — using shred (slow)"
        shred -v -n 3 -z "$disk"
    fi

    log "Wiping all signatures on $disk"
    wipefs -a "$disk"
}

# ------------------ Argument parsing ------------------

partitions=()
disks=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--partitions)
            shift
            while [[ $# -gt 0 && "$1" != -* ]]; do
                partitions+=("$1")
                shift
            done
            ;;
        -d|--disks)
            shift
            while [[ $# -gt 0 && "$1" != -* ]]; do
                disks+=("$1")
                shift
            done
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            fail "Unknown argument: $1. Use -h for help."
            ;;
    esac
done

if [[ ${#partitions[@]} -eq 0 && ${#disks[@]} -eq 0 ]]; then
    fail "No partitions or disks specified. Use --help."
fi

if [[ "$(id -u)" -ne 0 ]]; then
    fail "This script must be run as root."
fi

# ------------------ Main Execution ------------------

for part in "${partitions[@]}"; do
    [[ -b "$part" ]] || fail "Partition $part does not exist or is not a block device."
    secure_erase_partition "$part"
done

for disk in "${disks[@]}"; do
    [[ -b "$disk" ]] || fail "Disk $disk does not exist or is not a block device."
    secure_erase_disk "$disk"
done

log "Secure erase completed."
