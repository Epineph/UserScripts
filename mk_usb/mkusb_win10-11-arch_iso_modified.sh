#!/bin/bash

set -e

# Function to check available disk space
check_disk_space() {
    local required_space=$1
    local available_space=$(df /home/iso_downloads | awk 'NR==2 {print $4}')
    if [[ $available_space -lt $required_space ]]; then
        echo "Insufficient disk space. Required: $required_space, Available: $available_space"
        exit 1
    fi
}

# Create the directory if it does not exist
mkdir -p /home/iso_downloads

# Function to download the latest Arch ISO
download_arch_iso() {
    ISO_URL="https://mirrors.dotsrc.org/archlinux/iso/2024.05.01/archlinux-2024.05.01-x86_64.iso"
    ISO_FILE="/home/iso_downloads/archlinux.iso"
    check_disk_space 8000000 # Check for at least 8 GB of free space
    echo "Downloading the latest Arch Linux ISO from $ISO_URL..."
    curl -L -o "$ISO_FILE" "$ISO_URL"
}

# Function to download Windows 10 ISO
download_win10_iso() {
    ISO_URL="https://software.download.prss.microsoft.com/dbazure/Win10_22H2_EnglishInternational_x64v1.iso?t=76cf4202-ee77-4b16-8e41-bc2db36266e1&P1=1717201056&P2=601&P3=2&P4=V7afY6FiJ7x9NSoSfVmxWq2KYiE8n9Rz%2b0J%2fpkGFlZjG0imUE35Y7Pr5AuEj%2fie5t2VmQnlYAk1U4daSHQZO%2fEq6%2fwAQUN0LJ%2bZCcnVrJ2QXOAabyvytbgCPB2SjYeI5p%2fsf5Dh3CqCcMw%2fymMIx741wBo359ek4bB26LeI7eWXGI7YpcKMcr4RXWH3w3gOf0nri04EPG0%2fdPYJ0MdEpIsGD2OBriQc%2ba89EJV2KNxEj5e9y4svEQI3bIBR0Ll5K87Ss7wlGJ2kFZ5zP4rAKHre7xO7E2EyGrn3XBvwXYmcAHLPeSMxurgDg5hhKOw5TgfjBTahy3U7xXMBzYm5yoA%3d%3d"
    ISO_FILE="/home/iso_downloads/Win10.iso"
    check_disk_space 8000000 # Check for at least 8 GB of free space
    echo "Downloading Windows 10 ISO from $ISO_URL..."
    curl -L -o "$ISO_FILE" "$ISO_URL"
}

# Function to download Windows 11 ISO
download_win11_iso() {
    ISO_URL="https://software.download.prss.microsoft.com/dbazure/Win11_23H2_EnglishInternational_x64v2.iso?t=49ff3a2a-0bc3-47bb-8ed3-535bf1588119&P1=1717201498&P2=601&P3=2&P4=LckSofy%2bUYpK9umsCYk4KYYjdsa86N8SJiuuACvwovOmEqQ%2bbxAgbpmy1oLLLqSHsrAyXgybD4h4CjsTRNAjGN2k2j1o4WYYQ6qOZJHHt9luRSmS5firptNpIBthojnZYBv6XpO0StVWaLZ4BC6ZL%2fqTIhlZfrxS4B7ou%2fkuISP8fGUhrNsONY63kdWOIu5VrvfklNUnKYjZPGobawVCWHpB9XSjTRZGcPxmDk34nnflsGaQQDUlxcpyWCKVcb3FdC5H0W%2fFDgGodx4We8DTmQ3YjeqE5zYU7LHYsW%2f6QjCVrWvJK355u6UW47h2UPhZXsp9dJ42jeIn1pwOguzWaA%3d%3d"
    ISO_FILE="/home/iso_downloads/Win11.iso"
    check_disk_space 8000000 # Check for at least 8 GB of free space
    echo "Downloading Windows 11 ISO from $ISO_URL..."
    curl -L -o "$ISO_FILE" "$ISO_URL"
}

# Prompt the user to select the OS
echo "Select the OS to create a bootable USB for:"
options=("Arch Linux" "Windows 10" "Windows 11")
select opt in "${options[@]}"
do
    case $opt in
        "Arch Linux")
            echo "You chose Arch Linux."
            download_arch_iso
            break
            ;;
        "Windows 10")
            echo "You chose Windows 10."
            download_win10_iso
            break
            ;;
        "Windows 11")
            echo "You chose Windows 11."
            download_win11_iso
            break
            ;;
        *) echo "Invalid option $REPLY";;
    esac
done

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
if [[ "$confirm" != "y" ]]; then
    echo "Aborting."
    exit 1
fi

# Ensure no partitions are in use
sudo fuser -k ${USB_DEVICE}

# Unmount the device if mounted
umount ${USB_DEVICE}* 2>/dev/null || true

# Reinitialize the partition table
parted ${USB_DEVICE} --script mklabel msdos
parted ${USB_DEVICE} --script mkpart primary fat32 1MiB 100%
parted ${USB_DEVICE} --script set 1 boot on

# Inform the kernel of partition table changes
partprobe ${USB_DEVICE}

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

# Install GRUB bootloader if Arch Linux
if [[ "$opt" == "Arch Linux" ]]; then
    grub-install --target=i386-pc --boot-directory=/mnt/usb/boot ${USB_DEVICE}
    grub-mkconfig -o /mnt/usb/boot/grub/grub.cfg
fi

# Unmount everything
umount /mnt/iso
umount /mnt/usb

# Safely remove directories if empty
rmdir /mnt/iso 2>/dev/null || true
rmdir /mnt/usb 2>/dev/null || true

echo "USB is now bootable with $opt."

