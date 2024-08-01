#!/bin/bash

# Variables (edit these as needed)
DISK="/dev/sda"
EFI_PARTITION="${DISK}1"
BOOT_PARTITION="${DISK}2"
LVM_PARTITION="${DISK}3"
VG_NAME="vg0"
ROOT_SIZE="20G"
SWAP_SIZE="8G"
HOSTNAME="myhostname"
LOCALE="en_US.UTF-8"
TIMEZONE="Region/City"

# Load keyboard layout
loadkeys us

# Update system clock
timedatectl set-ntp true

# Partition the disk (manual step, uncomment to automate)
# cfdisk $DISK

# Format the partitions
mkfs.fat -F32 $EFI_PARTITION
mkfs.ext4 $BOOT_PARTITION

# Encrypt the LVM partition
cryptsetup luksFormat $LVM_PARTITION
cryptsetup open $LVM_PARTITION cryptlvm

# Set up LVM
pvcreate /dev/mapper/cryptlvm
vgcreate $VG_NAME /dev/mapper/cryptlvm
lvcreate -L $SWAP_SIZE $VG_NAME -n swap
lvcreate -L $ROOT_SIZE $VG_NAME -n root
lvcreate -l 100%FREE $VG_NAME -n home

# Encrypt the swap and home logical volumes
cryptsetup luksFormat /dev/$VG_NAME/swap
cryptsetup open /dev/$VG_NAME/swap cryptswap

cryptsetup luksFormat /dev/$VG_NAME/home
cryptsetup open /dev/$VG_NAME/home crypthome

# Format the logical volumes
mkfs.ext4 /dev/$VG_NAME/root
mkfs.ext4 /dev/mapper/crypthome
mkswap /dev/mapper/cryptswap

# Mount the file systems
mount /dev/$VG_NAME/root /mnt
mkdir /mnt/home
mount /dev/mapper/crypthome /mnt/home
mkdir /mnt/boot
mount $BOOT_PARTITION /mnt/boot
mkdir -p /mnt/boot/efi
mount $EFI_PARTITION /mnt/boot/efi
swapon /dev/mapper/cryptswap

# Install essential packages
pacstrap /mnt base linux linux-firmware lvm2

# Generate the fstab file
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot into the new system
arch-chroot /mnt <<EOF

# Set the time zone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Localization
sed -i "s/#$LOCALE/$LOCALE/" /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

# Configure the network
echo "$HOSTNAME" > /etc/hostname​⬤