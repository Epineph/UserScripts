#!/bin/bash


sudo sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf


timedatectl set-ntp true

# Update mirrors
pacman -Syyy

# Install required utilities
pacman -S fzf mdadm lvm2 --needed --noconfirm

# Disk Selection
selected_disks=$(lsblk -d -o NAME,SIZE,MODEL | grep -E '^sd|^nvme' | fzf -m | awk '{print "/dev/"$1}')

# Ensure two disks are selected for RAID
if [ "$(echo "$selected_disks" | wc -l)" -lt 2 ]; then
    echo "Select at least two disks for RAID configuration."
    exit 1
fi

# RAID Configuration
echo "Setting up RAID-0 (striping) across selected disks"
mdadm --create --verbose /dev/md0 --level=0 --raid-devices=$(echo "$selected_disks" | wc -l) $selected_disks

