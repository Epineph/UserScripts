#!/bin/bash

# Check for root permissions
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

# Get the list of logical volumes
LV_PATHS=$(lvs --noheadings -o lv_path)

echo "Logical Volume Space Usage:"
echo "============================"
for LV_PATH in $LV_PATHS; do
  LV_NAME=$(basename "$LV_PATH")
  MOUNT_POINT=$(findmnt -nr -o TARGET -S "$LV_PATH")

  if [ -z "$MOUNT_POINT" ]; then
    echo "$LV_NAME is not mounted"
  else
    USAGE=$(df -h "$MOUNT_POINT" | awk 'NR==2 {print $3 "/" $2 " (" $5 " used)"}')
    echo "$LV_NAME ($MOUNT_POINT): $USAGE"
  fi
done

echo "============================"

