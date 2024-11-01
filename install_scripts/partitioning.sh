#!/bin/bash

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Define the target drive
target_drive="/dev/nvme0n1"

echo "Beginning partitioning and LVM setup..."

# No removal is specified here; ensure partitions beyond Windows are cleared if needed
# Create an XBOOTLDR partition with the specified GUID
parted $target_drive mkpart XBOOTLDR 105MiB 1105MiB
parted $target_drive set 4 esp on

# Set the correct type GUID for XBOOTLDR
sgdisk -t 3:bc13c2ff-59e6-4262-a352-b275fd6f7172 $target_drive

# Assuming the rest of the disk is for LVM
parted -s $target_drive mkpart extended 1106MiB 100%
parted -s $target_drive set 4 lvm on

# Apply changes
partprobe $target_drive

# Initialize PV and create a VG on the new LVM partition (assuming it's partition 4)
pvcreate ${target_drive}p4
vgcreate vg0 ${target_drive}p4

# Create LVs for root and swap within the VG
lvcreate -L 30G vg0 -n lv_root
lvcreate -L 8G vg0 -n lv_swap

# Format the LVs
mkfs.ext4 /dev/vg0/lv_root
mkswap /dev/vg0/lv_swap

# Format the XBOOTLDR partition (if needed, e.g., with FAT32 for compatibility)
mkfs.fat -F32 ${target_drive}p3

echo "Partitioning and LVM setup complete."
