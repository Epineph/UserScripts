#!/bin/bash

#set -e  # Exit immediately if a command exits with a non-zero status

# Enable multilib repository and parallel downloads
sudo sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
sudo sed -i 's/^#\(ParallelDownloads = 5\)/\1/' /etc/pacman.conf

# Synchronize time
timedatectl set-ntp true

# Update mirrors and package database
pacman -Syyy

# Install required utilities
pacman -S fzf lvm2 git mdadm --needed --noconfirm

# Disk Selection
selected_disks=$(lsblk -d -o NAME,SIZE,MODEL | grep -E '^sd|^nvme' | fzf -m | awk '{print "/dev/"$1}')

# Ensure at least one disk is selected
if [ -z "$selected_disks" ]; then
    echo "Select at least one disk for installation."
    exit 1
fi

# Stop any existing RAID arrays (if any)
for disk in $selected_disks; do
    mdadm --zero-superblock --force ${disk}* || true
done

# Wipe disks
for disk in $selected_disks; do
    wipefs --all --force $disk
done

# Partition Disks
for disk in $selected_disks; do
    echo "Partitioning $disk..."
    parted $disk --script mklabel gpt
    parted $disk --script mkpart ESP fat32 1MiB 513MiB
    parted $disk --script set 1 esp on
    parted $disk --script mkpart primary 513MiB 100%
done

# Ensure partitions are recognized
partprobe

if [ "$(echo "$selected_disks" | wc -l)" -gt 1 ]; then
    # Create RAID-0 Array if more than one disk is selected
    echo "Setting up RAID-0 (striping) across selected disks"
    partitions=$(for disk in $selected_disks; do echo "${disk}p2"; done)
    mdadm --create --verbose /dev/md0 --level=0 --raid-devices=$(echo "$selected_disks" | wc -l) $partitions
    sleep 10  # Wait for RAID array to initialize
    pvcreate /dev/md0
    vgcreate volgroup0 /dev/md0
else
    # Single disk setup
    echo "Single disk setup detected"
    pvcreate ${selected_disks}p2
    vgcreate volgroup0 ${selected_disks}p2
fi

# Create Logical Volumes
lvcreate -L 130GB volgroup0 -n lv_root
lvcreate -L 32GB volgroup0 -n lv_swap
lvcreate -l 100%FREE volgroup0 -n lv_home

# Encrypt the logical volumes
echo -n "Enter passphrase for LUKS encryption: "
read -s LUKS_PASSPHRASE
echo
echo -n "$LUKS_PASSPHRASE" | cryptsetup luksFormat /dev/volgroup0/lv_root -
echo -n "$LUKS_PASSPHRASE" | cryptsetup open /dev/volgroup0/lv_root cryptroot -
echo -n "$LUKS_PASSPHRASE" | cryptsetup luksFormat /dev/volgroup0/lv_swap -
echo -n "$LUKS_PASSPHRASE" | cryptsetup open /dev/volgroup0/lv_swap cryptswap -
echo -n "$LUKS_PASSPHRASE" | cryptsetup luksFormat /dev/volgroup0/lv_home -
echo -n "$LUKS_PASSPHRASE" | cryptsetup open /dev/volgroup0/lv_home crypthome -

# Format the logical volumes
mkfs.ext4 /dev/mapper/cryptroot
mkfs.ext4 /dev/mapper/crypthome
mkswap /dev/mapper/cryptswap

# Format the ESP partitions
for disk in $selected_disks; do
    mkfs.fat -F32 ${disk}p1
done

# Mount Partitions
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{boot/efi,home}
mount $(echo $selected_disks | awk '{print $1"p1"}') /mnt/boot/efi
mount /dev/mapper/crypthome /mnt/home
swapon /dev/mapper/cryptswap

# Install essential packages
pacstrap /mnt base linux linux-firmware lvm2

# Generate the fstab file
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot into the new system
arch-chroot /mnt <<EOF

# Set timezone
ln -sf /usr/share/zoneinfo/Europe/Copenhagen /etc/localtime
hwclock --systohc

# Localization
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

# Configure the network
echo "archlinux" > /etc/hostname
cat <<EOT > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   archlinux.localdomain archlinux
EOT

# Set the root password
#echo "root:password" | chpasswd

# Install necessary packages
pacman -S grub efibootmgr networkmanager

# Configure mkinitcpio
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Install GRUB
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB

# Configure GRUB
sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="cryptdevice=\/dev\/volgroup0\/lv_root:cryptroot root=\/dev\/mapper\/cryptroot"/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# Add crypttab entries
echo "cryptroot /dev/volgroup0/lv_root none luks" > /etc/crypttab
echo "cryptswap /dev/volgroup0/lv_swap none luks" >> /etc/crypttab
echo "crypthome /dev/volgroup0/lv_home none luks" >> /etc/crypttab

# Enable services
systemctl enable NetworkManager

EOF

# Exit and reboot
