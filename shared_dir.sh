#!/bin/bash

# Function to display the help section
show_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

This script configures a partition to be mounted at a specified directory using its UUID in /etc/fstab.

Options:
  -p, --partition   Partition to mount (e.g., /dev/sdXn)
  -d, --directory   Directory to mount the partition (e.g., /home/shared)
  -h, --help        Show this help message and exit

Examples:
  $0 -p /dev/sdb1 -d /home/shared
  $0 --partition /dev/sda1 --directory /mnt/shared
EOF
  exit 1
}

# Function to validate partition
validate_partition() {
  if [[ ! -b "$1" ]]; then
    echo "Error: '$1' is not a valid block device."
    exit 1
  fi
}

# Function to validate directory
validate_directory() {
  if [[ ! -d "$1" ]]; then
    echo "Error: '$1' is not a valid directory."
    exit 1
  fi
}

# Default values
PARTITION=""
DIR=""

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -p|--partition)
      PARTITION="$2"
      shift 2
      ;;
    -d|--directory)
      DIR="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      ;;
    *)
      echo "Unknown option: $1"
      show_help
      ;;
  esac
done

# Prompt for missing inputs
if [[ -z "$PARTITION" ]]; then
  read -rp "Enter the partition (e.g., /dev/sdXn): " PARTITION
fi
validate_partition "$PARTITION"

if [[ -z "$DIR" ]]; then
  read -rp "Enter the directory (e.g., /home/shared): " DIR
fi
validate_directory "$DIR"

# Fetch UUID of the partition
UUID=$(blkid -s UUID -o value "$PARTITION")
if [[ -z "$UUID" ]]; then
  echo "Error: Could not fetch UUID for $PARTITION."
  exit 1
fi

# Add entry to /etc/fstab
FSTAB_ENTRY="UUID=$UUID $DIR ntfs-3g defaults,uid=1000,gid=1000,dmask=0022,fmask=0022 0 0"
if grep -q "$UUID" /etc/fstab; then
  echo "Entry for partition $PARTITION already exists in /etc/fstab."
else
  echo -e "\n# Added by $0 script\n$FSTAB_ENTRY" | sudo tee -a /etc/fstab
  echo "Added the following entry to /etc/fstab:"
  echo "$FSTAB_ENTRY"
fi

# Reload fstab and mount
sudo mount -a
if mount | grep "$DIR"; then
  echo "Partition successfully mounted at $DIR."
else
  echo "Error: Failed to mount $DIR. Check your /etc/fstab."
fi