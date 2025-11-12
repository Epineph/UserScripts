#!/bin/bash

# Define your volume group and logical volume names
VG_NAME="vg_name"
LV_NAME="lv_home"
PHYSICAL_PARTITION="/dev/sda2"

# Function to prompt for user confirmation
confirm() {
    read -r -p "$1 [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            true
            ;;
        *)
            false
            ;;
    esac
}

# Check current usage
echo "Checking current usage of logical volume..."
LV_PATH="/dev/$VG_NAME/$LV_NAME"
CURRENT_USAGE=$(df -h | grep $LV_PATH | awk '{print $5}' | sed 's/%//')
CURRENT_SIZE=$(lvdisplay $LV_PATH | grep "LV Size" | awk '{print $3 $4}')

echo "Current usage of $LV_PATH: $CURRENT_USAGE%"
echo "Current size of $LV_PATH: $CURRENT_SIZE"

# Determine free space to be reduced
if [ $CURRENT_USAGE -lt 90 ]; then
  REDUCE_SIZE=$(echo "scale=2; (100 - $CURRENT_USAGE) / 2" | bc)
  echo "You can safely reduce the size of the logical volume by approximately $REDUCE_SIZE GB."
else
  echo "Not enough free space to reduce the logical volume safely."
  exit 1
fi

# Prompt to reduce the logical volume
if confirm "Do you want to reduce the logical volume by $REDUCE_SIZE GB?"; then
    NEW_SIZE=$(echo "$CURRENT_SIZE - $REDUCE_SIZE" | bc)
    echo "Reducing the logical volume by $REDUCE_SIZE GB..."
    sudo lvreduce -L -${REDUCE_SIZE}G $LV_PATH -y
    sudo resize2fs $LV_PATH
    echo "Logical volume reduced to $NEW_SIZE GB."
else
    echo "Logical volume reduction cancelled."
    exit 1
fi

# Check physical volume usage
echo "Checking current usage of physical volume..."
CURRENT_PV_SIZE=$(pvdisplay | grep "PV Size" | awk '{print $3 $4}')

echo "Current size of physical volume: $CURRENT_PV_SIZE"

# Prompt to shrink the physical volume
if confirm "Do you want to shrink the physical volume to $NEW_SIZE GB?"; then
    echo "Shrinking the physical volume..."
    sudo pvresize --setphysicalvolumesize ${NEW_SIZE}G $PHYSICAL_PARTITION
    echo "Physical volume resized to $NEW_SIZE GB."
else
    echo "Physical volume shrinking cancelled."
    exit 1
fi

# Instructions for partition resizing
echo "Physical volume resized. Please boot from a live CD/USB to resize the physical partition."

echo "Use the following commands in the live environment:"
echo "sudo parted $PHYSICAL_PARTITION"
echo "(parted) print"
echo "(parted) resizepart [PartitionNumber] [NewEnd]"
echo "Then, boot into Windows and extend the Windows partition using Disk Management."

echo "Process completed."
