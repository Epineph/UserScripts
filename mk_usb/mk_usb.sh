#!/bin/bash

# WARNING: This script is potentially dangerous. Make sure to replace /dev/sdX with your actual USB device.
# This will ERASE ALL DATA on the specified device!

# Define the device and the ISO file
USB_DEVICE="/dev/sdX"  # Be very careful with this setting!
ISO_FILE="path_to_your_arch.iso"

# Ensure the device is not mounted
umount ${USB_DEVICE}* 2>/dev/null

# Create a new partition table
parted ${USB_DEVICE} --script mklabel msdos

# Create a new primary partition and make it bootable
parted ${USB_DEVICE} --script mkpart primary fat32 1MiB 100%
parted ${USB_DEVICE} --script set 1 boot on

# Format the partition to FAT32
mkfs.fat -F32 ${USB_DEVICE}1

# Mount the USB device
mkdir -p /mnt/usb
mount ${USB_DEVICE}1 /mnt/usb

# Mount the ISO file
mkdir -p /mnt/iso
if ! mount -o loop ${ISO_FILE} /mnt/iso; then
    echo "Failed to mount ISO. Exiting."
    exit 1
fi

# Copy files from the ISO to the USB
cp -r /mnt/iso/* /mnt/usb/

# Install GRUB bootloader
grub-install --target=i386-pc --boot-directory=/mnt/usb/boot ${USB_DEVICE}
grub-mkconfig -o /mnt/usb/boot/grub/grub.cfg

# Unmount everything
umount /mnt/iso
umount /mnt/usb
rmdir /mnt/iso
rmdir /mnt/usb

echo "USB is now bootable with Arch Linux using GRUB."
