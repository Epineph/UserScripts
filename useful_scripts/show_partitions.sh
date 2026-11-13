#!/usr/bin/env bash
#
# show_partitions.sh
# 
# A simple script to display all mounted partitions and their space usage,
# including LVM volumes. It also prints a helpful summary from lsblk.
#
# Usage: ./show_partitions.sh

set -euo pipefail

echo "===== Block Device Overview (lsblk) ====="
lsblk -o NAME,FSTYPE,TYPE,SIZE,MOUNTPOINT

echo
echo "===== Disk Usage for Mounted Partitions (df) ====="
# Show usage in a human-readable format (-h), skip temp filesystems
df -h -x tmpfs -x devtmpfs -x overlay

