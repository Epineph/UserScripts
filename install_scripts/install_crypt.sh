#!/bin/bash

# Set variables
DISK="/dev/nvme0n1"
EFI_PARTITION="${DISK}p1"
BOOT_PARTITION="${DISK}p2"
LVM_PARTITION="${DISK}p3"

# Set up keyboard layout (if needed)
loadkeys dk

# Verify network connectivity
ping -c 3 archlinux.org

# Update the system clock
timedatectl set-ntp true

# Partition the disk
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 1024MiB
parted -s "$DISK" set 1 boot on
parted -s "$DISK" mkpart primary ext4 1025MiB 2048MiB
parted -s "$DISK" mkpart primary ext4 2049MiB 100%

# Format the partitions
mkfs.fat -F32 "$EFI_PARTITION"
mkfs.ext4 "$BOOT_PARTITION"

# Encrypt the LVM partition using LUKS
echo -n "Enter passphrase for LUKS encryption: "
read -s LUKS_PASSPHRASE
echo -n "$LUKS_PASSPHRASE" | cryptsetup luksFormat "$LVM_PARTITION" -
echo -n "$LUKS_PASSPHRASE" | cryptsetup open "$LVM_PARTITION" cryptlvm -

# Set up LVM
pvcreate /dev/mapper/cryptlvm
vgcreate vg0 /dev/mapper/cryptlvm
lvcreate -L 8G vg0 -n swap
lvcreate -L 20G vg0 -n root
lvcreate -l 100%FREE vg0 -n home

# Encrypt the swap and home logical volumes
echo -n "$LUKS_PASSPHRASE" | cryptsetup luksFormat /dev/vg0/swap -
echo -n "$LUKS_PASSPHRASE" | cryptsetup open /dev/vg0/swap cryptswap -
echo -n "$LUKS_PASSPHRASE" | cryptsetup luksFormat /dev/vg0/home -
echo -n "$LUKS_PASSPHRASE" | cryptsetup open /dev/vg0/home crypthome -

# Format the logical volumes
mkfs.ext4 /dev/vg0/root
mkfs.ext4 /dev/mapper/crypthome
mkswap /dev/mapper/cryptswap

# Mount the file systems
mount /dev/vg0/root /mnt
mkdir /mnt/home
mount /dev/mapper/crypthome /mnt/home
mkdir /mnt/boot
mount "$BOOT_PARTITION" /mnt/boot
mkdir -p /mnt/boot/efi
mount "$EFI_PARTITION" /mnt/boot/efi
swapon /dev/mapper/cryptswap

# Install essential packages
pacstrap /mnt base linux linux-firmware lvm2

# Generate the fstab file
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot into the new system
arch-chroot /mnt <<EOF

# Set the time zone
ln -sf /usr/share/zoneinfo/Region/City /etc/localtime
hwclock --systohc

# Localization
echo "en_DK.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_DK.UTF-8" > /etc/locale.conf
echo "KEYMAP=dk" > /etc/vconsole.conf

# Configure the network
echo "myhostname" > /etc/hostname
cat <<EOT > /etc/hosts
127.0.0.1    localhost
::1          localhost
127.0.1.1    myhostname.localdomain myhostname
EOT

# Set the root password
echo "root:password" | chpasswd

# Install necessary packages
pacman -S grub efibootmgr networkmanager

# Configure mkinitcpio
sed -i 's/^HOOKS=(.*)/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Install GRUB
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB

# Configure GRUB
sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="cryptdevice=\/dev\/sda3:cryptlvm root=\/dev\/vg0\/root"/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# Add crypttab entries
echo "cryptswap /dev/vg0/swap none luks" >> /etc/crypttab
echo "crypthome /dev/vg0/home none luks" >> /etc/crypttab

# Enable NetworkManager
systemctl enable NetworkManager

EOF

# Exit and reboot
umount -R /mnt
swapoff -a
reboot