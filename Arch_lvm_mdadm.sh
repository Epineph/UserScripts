#!/bin/bash

# Enable multilib repository
sudo sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf

# Synchronize time
timedatectl set-ntp true

# Update mirrors and package database
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

# Partition Disks
for disk in $selected_disks; do
    echo "Partitioning $disk..."
    parted $disk -- mklabel gpt
    parted $disk -- mkpart primary fat32 1MiB 2049MiB
    parted $disk -- set 1 esp on
    parted $disk -- mkpart primary 2049MiB 100%
done

# Create RAID-0 Array
echo "Setting up RAID-0 (striping) across selected disks"
mdadm --create --verbose /dev/md0 --level=0 --raid-devices=$(echo "$selected_disks" | wc -l) $(echo $selected_disks | awk '{print $1"2 " $2"2"}')

# Wait for RAID array to initialize
sleep 10

# Create Physical Volumes on RAID Array
pvcreate /dev/md0

# Create Volume Group
vgcreate volgroup0 /dev/md0

# Create Logical Volumes
lvcreate -L 130GB volgroup0 -n lv_root
lvcreate -L 32GB volgroup0 -n lv_swap
lvcreate -l 100%FREE volgroup0 -n lv_home

# Format Partitions
mkfs.fat -F32 $(echo $selected_disks | awk '{print $1"1"}')
mkfs.ext4 /dev/volgroup0/lv_root
mkfs.ext4 /dev/volgroup0/lv_home
mkswap /dev/volgroup0/lv_swap

# Mount Partitions
mount /dev/volgroup0/lv_root /mnt

mkdir -p /mnt/{boot/efi,home}
mount $(echo $selected_disks | awk '{print $1"1"}') /mnt/boot/efi
mount /dev/volgroup0/lv_home /mnt/home
swapon /dev/volgroup0/lv_swap

# Configure mdadm
mdadm --detail --scan | tee -a /mnt/etc/mdadm.conf

# Configure mkinitcpio
sudo sed -i 's/^HOOKS=.*$/HOOKS=(base udev autodetect modconf block mdadm_udev lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
cp /etc/mdadm.conf /mnt/etc/mdadm.conf
cp /etc/mkinitcpio.conf /mnt/etc/mkinitcpio.conf

echo "Pre-pacstrap setup is complete. You can now proceed with pacstrap to install the base system."
