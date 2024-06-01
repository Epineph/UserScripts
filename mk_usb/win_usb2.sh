#!/bin/bash

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
   echo "This script must be run as root" >&2
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


# Define ISO and USB variables
#ISO_FILE="/path/to/your/windows.iso"
#USB_DEVICE="/dev/sdx"  # Be extremely careful with this!

# Unmount the USB device if it is mounted
umount ${USB_DEVICE}* 2>/dev/null

# Create a new partition table
parted $USB_DEVICE --script mklabel msdos

# Create a primary NTFS partition
parted $USB_DEVICE --script mkpart primary ntfs 1MiB 100%
parted $USB_DEVICE --script set 1 boot on

# Format the partition to NTFS
mkfs.ntfs -F 32 ${USB_DEVICE}1

# Mount the USB device
mkdir -p /mnt/usb
mount ${USB_DEVICE}1 /mnt/usb

# Mount the ISO file
mkdir -p /mnt/iso
mount -o loop $ISO_FILE /mnt/iso

# Copy files from the ISO to the USB
cp -r /mnt/iso/* /mnt/usb/

# Installing a Microsoft-compatible Master Boot Record (MBR)
# ms-sys might be used if available (check your distribution's repository)
ms-sys -7 -w  ${USB_DEVICE}  # This writes a Windows 7 MBR; use -w for Windows 10

# Alternatively, use dd if ms-sys is not available:
# dd if=/usr/lib/syslinux/mbr/mbr.bin of=${USB_DEVICE}

# Unmount everything
umount /mnt/iso
umount /mnt/usb

# Remove mount directories
rmdir /mnt/iso
rmdir /mnt/usb

echo "USB is now bootable with Windows!"

