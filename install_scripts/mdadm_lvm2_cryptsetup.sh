#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Enable multilib repository and parallel downloads
sudo sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
sudo sed -i 's/^#\(ParallelDownloads = 5\)/\1/' /etc/pacman.conf

# Synchronize time
timedatectl set-ntp true

# Update mirrors and package database
pacman -Syyy

# Install required utilities
pacman -S fzf lvm2 git --needed --noconfirm

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
    partitions=$(for disk in $selected_disks; do echo "${disk}2"; done)
    mdadm --create --verbose /dev/md0 --level=0 --raid-devices=$(echo "$selected_disks" | wc -l) $partitions
    sleep 10  # Wait for RAID array to initialize
    pvcreate /dev/md0
    vgcreate volgroup0 /dev/md0
else
    # Single disk setup
    echo "Single disk setup detected"
    pvcreate ${selected_disks}2
    vgcreate volgroup0 ${selected_disks}2
fi

# Create Logical Volumes
lvcreate -L 130GB volgroup0 -n lv_root
lvcreate -L 32GB volgroup0 -n lv_swap
lvcreate -l 100%FREE volgroup0 -n lv_home

# Encrypt the logical volumes
echo -n "Enter passphrase for LUKS encryption: "
read -s LUKS_PASSPHRASE
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
    mkfs.fat -F32 ${disk}1
done

# Mount Partitions
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{boot/efi,home,proc,sys,dev,etc}
mount $(echo $selected_disks | awk '{print $1"1"}') /mnt/boot/efi
mount /dev/mapper/crypthome /mnt/home
swapon /dev/mapper/cryptswap

# Bind mount necessary filesystems
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys
mount --bind /dev /mnt/dev

# Configure mkinitcpio
sed -i -e 's/^HOOKS=.*$/HOOKS=(base systemd udev autodetect modconf block encrypt lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
cp /etc/mkinitcpio.conf /mnt/etc/mkinitcpio.conf
cp /etc/pacman.conf /mnt/etc/pacman.conf

# Pacstrap base system
pacstrap -P -K /mnt base base-devel lvm2 linux linux-headers linux-firmware intel-ucode efibootmgr networkmanager xdg-user-dirs xdg-utils sudo nano vim mtools dosfstools grub openssh git

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot into the new system
arch-chroot /mnt /bin/bash <<EOF

# Set timezone
ln -sf /usr/share/zoneinfo/Europe/Copenhagen /etc/localtime

# Generate /etc/locale.conf
echo "LANG=en_DK.UTF-8" > /etc/locale.conf

# Uncomment the locale in /etc/locale.gen and generate locales
sed -i 's/^#\(en_DK.UTF-8\)/\1/' /etc/locale.gen
locale-gen

# Set the keymap
echo "KEYMAP=dk" > /etc/vconsole.conf

# Set the hostname
echo "archlinux-desktop" > /etc/hostname

# Configure /etc/hosts
cat <<HOSTS > /etc/hosts
127.0.0.1       localhost
::1             localhost
127.0.1.1       archlinux-desktop.localdomain archlinux-desktop
HOSTS

# Create a new user
useradd -m -G wheel -s /bin/bash heini

# Configure sudoers
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers
echo "heini ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

# Enable services
systemctl enable NetworkManager
systemctl enable sshd

# Install and configure GRUB
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=arch_grub --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# Set root password interactively
echo "Insert root password: " && read -s root_password && echo -e "$root_password\n$root_password" | passwd root

# Set password for user heini interactively
echo "Insert heini password: " && read -s heini_password && echo -e "$heini_password\n$heini_password" | passwd heini

EOF

echo "Setup is complete. Reboot your system to apply the changes."