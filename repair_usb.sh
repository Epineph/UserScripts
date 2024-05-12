#!/bin/bash

# WARNING: Replace /dev/sdx with your actual USB drive identifier.
# Double-check this to avoid data loss.

USB_DRIVE="/dev/sdx"

# Ensure the device is not mounted
echo "Checking for mounted partitions on $USB_DRIVE"
for mount in $(mount | grep $USB_DRIVE | cut -d ' ' -f 1); do
    echo "Unmounting $mount"
    sudo umount $mount
done

# Create a new MBR partition table
echo "Creating new MBR partition table on $USB_DRIVE"
sudo parted $USB_DRIVE --script -- mklabel msdos

# Create a new primary FAT32 partition
echo "Creating primary FAT32 partition on $USB_DRIVE"
sudo parted $USB_DRIVE --script -- mkpart primary fat32 1MiB 100%

# Format the partition to FAT32
echo "Formatting partition to FAT32"
sudo mkfs.vfat -F 32 ${USB_DRIVE}1

# Check and repair the FAT32 filesystem
echo "Checking and repairing FAT32 filesystem"
sudo dosfsck -w -r -l -a -v -t ${USB_DRIVE}1

echo "Operation completed. USB drive is ready and should be compatible with Windows and Linux."
