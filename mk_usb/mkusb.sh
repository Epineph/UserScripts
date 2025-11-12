#!/bin/bash

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Check if fzf is installed and install if not
if ! command -v fzf &> /dev/null; then
    echo "fzf could not be found, installing..."
    pacman -Sy fzf --noconfirm
fi

# Select the ISO file using fzf
echo "Select the ISO file:"
ISO_FILE=$(find /home -type f -name "*.iso" | fzf --prompt="Choose ISO: ")

if [[ -z "$ISO_FILE" ]]; then
    echo "No ISO file selected. Exiting."
    exit 1
fi

# Select the target USB device
echo "Select the target USB device:"
USB_DEVICE=$(lsblk -dno NAME,SIZE,MODEL | fzf --prompt="Choose Device: " | awk '{print $1}')

if [[ -z "$USB_DEVICE" ]]; then
    echo "No USB device selected. Exiting."
    exit 1
fi

USB_DEVICE="/dev/$USB_DEVICE"

# Warning and confirmation
echo "WARNING: All data on $USB_DEVICE will be destroyed!"
read -p "Are you sure you want to continue? (y/N): " confirm
if [[ $confirm != "y" ]]; then
    echo "Aborting."
    exit 1
fi

# Unmount the device if mounted
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

# Safely remove directories if empty
rmdir /mnt/iso 2>/dev/null
rmdir /mnt/usb 2>/dev/null

echo "USB is now bootable with Arch Linux using GRUB."
