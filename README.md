# UserScripts

#!/bin/bash

# Update system clock
timedatectl set-ntp true

# Partition the disk
parted /dev/nvme0n1 --script -- mklabel gpt
parted /dev/nvme0n1 --script -- mkpart primary 1MiB 1GiB
parted /dev/nvme0n1 --script -- mkpart primary 1GiB 201GiB
parted /dev/nvme0n1 --script -- mkpart primary 201GiB 100%

# Format the boot partition
mkfs.fat -F32 /dev/nvme0n1p1

# Set up LUKS on the root and home partitions
cryptsetup luksFormat /dev/nvme0n1p3
cryptsetup open /dev/nvme0n1p3 cryptroot

# Create LVM physical volume and volume group
pvcreate /dev/mapper/cryptroot
vgcreate vg0 /dev/mapper/cryptroot

# Create logical volumes
lvcreate -L 110G vg0 -n root
lvcreate -l 100%FREE vg0 -n home

# Create filesystems
mkfs.ext4 /dev/vg0/root
mkfs.ext4 /dev/vg0/home

# Optional: Steps for shrinking and resizing the partition
# Uncomment and modify these steps if needed

## Get an overview of block devices
# lsblk

## Open the encrypted partition
# cryptsetup open /dev/nvme0n1p3 cryptroot

## Get an overview of the LVM structure
# pvdisplay
# vgdisplay
# lvdisplay

## Check the integrity of the filesystem
# e2fsck -f /dev/vg0/root

## Check the physical block size and used space within the filesystem
# fdisk -l /dev/vg0/root
# tune2fs -l /dev/vg0/root

## Calculate new sizes (example: shrink from 110G to 60G)
# CURRENT_SIZE_G=110
# NEW_SIZE_G=60
# FS_SIZE_G=$(echo "$NEW_SIZE_G * 0.9" | bc)

## Shrink the filesystem
# umount /mnt
# e2fsck -f /dev/vg0/root
# resize2fs /dev/vg0/root ${FS_SIZE_G}G
# e2fsck -f /dev/vg0/root

## Shrink the logical volume
# lvreduce -L ${NEW_SIZE_G}G /dev/vg0/root

## Extend the filesystem to the volume size
# resize2fs /dev/vg0/root

# Mount the filesystems
mount /dev/vg0/root /mnt
mkdir /mnt/home
mount /dev/vg0/home /mnt/home

# Mount the boot partition
mkdir /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot

# Install essential packages
pacstrap /mnt base linux linux-firmware lvm2

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot into the new system
arch-chroot /mnt

# Set the time zone
ln -sf /usr/share/zoneinfo/Region/City /etc/localtime
hwclock --systohc

# Localization
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

# Hostname
echo "myhostname" > /etc/hostname

# Hosts file
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1 localhost" >> /etc/hosts
echo "127.0.1.1 myhostname.localdomain myhostname" >> /etc/hosts

# Create crypttab entries
echo "cryptroot UUID=$(blkid -s UUID -o value /dev/nvme0n1p3) none luks,discard" >> /etc/crypttab

# Initramfs
sed -i 's/^HOOKS.*/HOOKS=(base udev autodetect modconf block keyboard keymap encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Root password
passwd

# Bootloader - systemd-boot
# Uncomment to use systemd-boot
# bootctl --path=/boot install

# Bootloader configuration - systemd-boot
# Uncomment to use systemd-boot
# cat <<EOF > /boot/loader/entries/arch.conf
# title Arch Linux
# linux /vmlinuz-linux
# initrd /initramfs-linux.img
# options cryptdevice=UUID=$(blkid -s UUID -o value /dev/nvme0n1p3):cryptroot root=/dev/vg0/root rw
# EOF

# Bootloader - GRUB
# Uncomment the lines below to use GRUB instead of systemd-boot

pacman -S grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Configure /etc/default/grub for encrypted disk
sed -i 's/^GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="cryptdevice=UUID=$(blkid -s UUID -o value /dev/nvme0n1p3):cryptroot root=\/dev\/vg0\/root"/' /etc/default/grub
sed -i 's/^#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# Enable swap file
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
echo '/swapfile none swap defaults 0 0' >> /etc/fstab

# Enable swap
swapon /swapfile

# Exit chroot
exit

# Unmount partitions
umount -R /mnt

# Reboot the system
reboot

Explanation:

	1.	Bootloader Configuration: The script now includes both systemd-boot and GRUB configurations, with systemd-boot lines commented out.
	2.	GRUB Configuration: The necessary changes to /etc/default/grub are included, such as setting GRUB_CMDLINE_LINUX for encrypted root and enabling GRUB_ENABLE_CRYPTODISK.
	3.	Switching Bootloaders: To use GRUB, ensure the systemd-boot lines are commented out and GRUB lines are uncommented.

This setup provides the flexibility to choose between systemd-boot and GRUB, with clear instructions on how to switch between them.