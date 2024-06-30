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
pacman -S fzf mdadm lvm2 git --needed --noconfirm

# Disk Selection
selected_disks=$(lsblk -d -o NAME,SIZE,MODEL | grep -E '^sd|^nvme' | fzf -m | awk '{print "/dev/"$1}')

# Ensure two disks are selected for RAID
if [ "$(echo "$selected_disks" | wc -l)" -lt 2 ]; then
    echo "Select at least two disks for RAID configuration."
    exit 1
fi

# Stop any existing RAID arrays
mdadm --zero-superblock --force $(for disk in $selected_disks; do echo "${disk}p2"; done)

# Wipe disks
for disk in $selected_disks; do
    wipefs --all --force $disk
done

# Partition Disks
for disk in $selected_disks; do
    echo "Partitioning $disk..."
    parted $disk --script mklabel gpt
    parted $disk --script mkpart ESP fat32 1MiB 2049MiB
    parted $disk --script set 1 esp on
    parted $disk --script mkpart primary 2049MiB 100%
done

# Ensure partitions are recognized
partprobe

# Create RAID-0 Array
echo "Setting up RAID-0 (striping) across selected disks"
partitions=$(for disk in $selected_disks; do echo "${disk}p2"; done)
mdadm --create --verbose /dev/md0 --level=0 --raid-devices=$(echo "$selected_disks" | wc -l) $partitions

# Wait for RAID array to initialize
sleep 10

# Create Physical Volumes on RAID Array
pvcreate /dev/md0

# Create Volume Group
vgcreate volgroup0 /dev/md0

# Create Logical Volumes
yes | lvcreate -L 130GB volgroup0 -n lv_root
yes | lvcreate -L 32GB volgroup0 -n lv_swap
yes | lvcreate -l 100%FREE volgroup0 -n lv_home

# Format Partitions
for disk in $selected_disks; do
    mkfs.fat -F32 ${disk}p1
done
mkfs.ext4 /dev/volgroup0/lv_root
mkfs.ext4 /dev/volgroup0/lv_home
mkswap /dev/volgroup0/lv_swap

# Mount Partitions
mount /dev/volgroup0/lv_root /mnt

mkdir -p /mnt/{boot/efi,home,proc,sys,dev,etc}
mount $(echo $selected_disks | awk '{print $1"p1"}') /mnt/boot/efi
mount /dev/volgroup0/lv_home /mnt/home
swapon /dev/volgroup0/lv_swap

# Bind mount necessary filesystems
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys
mount --bind /dev /mnt/dev

# Configure mdadm
mdadm --detail --scan | tee -a /mnt/etc/mdadm.conf

# Configure mkinitcpio
sed -i -e 's/^HOOKS=.*$/HOOKS=(base systemd udev autodetect modconf block mdadm_udev lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
cp /etc/mkinitcpio.conf /mnt/etc/mkinitcpio.conf
cp /etc/pacman.conf /mnt/etc/pacman.conf

pacstrap -P -K /mnt base base-devel lvm2 mdadm linux linux-headers nvidia nvidia-settings nvidia-utils linux-firmware intel-ucode efibootmgr networkmanager xdg-user-dirs xdg-utils sudo nano vim mtools dosfstools java-runtime python-setuptools ntfs-3g archinstall archiso arch-install-scripts

sleep 2

genfstab -U /mnt >> /mnt/etc/fstab

# Chroot into the new system and complete configuration
arch-chroot /mnt /bin/bash <<EOF

# Set up localization and timezone
echo "en_DK.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_DK.UTF-8" > /etc/locale.conf
echo "KEYMAP=dk" > /etc/vconsole.conf
ln -sf /usr/share/zoneinfo/Europe/Copenhagen /etc/localtime
hwclock --systohc

# Set hostname and hosts
echo "archlinux-desktop" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "127.0.1.1 archlinux-desktop.localdomain archlinux-desktop" >> /etc/hosts

# Set root password
echo "root:132" | chpasswd

# Create user heini
useradd -m -G wheel -s /bin/bash heini
echo "heini:132" | chpasswd

# Configure sudoers
sed -i 's/^# \(%wheel ALL=(ALL:ALL) ALL\)/\1/' /etc/sudoers
echo "heini ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

# Change user to heini and set up repositories
su - heini <<EOF2
cd \$HOME
mkdir repos
cd repos
git clone https://github.com/Epineph/UserScripts
git clone https://github.com/Epineph/generate_install_scripts
git clone https://github.com/JaKooLit/Arch-Hyprland
git clone https://aur.archlinux.org/yay.git
git clone https://aur.archlinux.org/paru.git

# Copy script and update .bashrc
sudo cp /home/heini/repos/UserScripts/log_scripts/gen_log.sh /usr/local/bin/gen_log
echo 'export PATH=/usr/local/bin:\$PATH' >> /home/heini/.bashrc

# Set permissions
sudo chown -R heini:heini /home/heini/repos
sudo chmod -R u+rwx /home/heini/repos
sudo chown -R heini:heini /usr/local/bin
sudo chmod -R u+rwx /usr/local/bin

# Source .bashrc
source /home/heini/.bashrc

# Build and install yay and paru
cd /home/heini/repos/yay
makepkg -si --noconfirm

cd /home/heini/repos/paru
makepkg -si --noconfirm
EOF2

# Install and configure GRUB
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=arch_grub --recheck
grub-mkconfig -o /boot/grub/grub.cfg

EOF

echo "Installation and configuration complete. Please reboot into your 
