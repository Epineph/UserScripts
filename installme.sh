#!/bin/bash

#set -e  # Exit immediately if a command exits with a non-zero status

# Unmount and clean up previous setups, ignoring errors
umount -l /mnt 2>/dev/null || true
swapoff -a
yes | vgremove volgroup0 2>/dev/null || true
mdadm --stop /dev/md0 2>/dev/null || true

# Enable multilib repository and parallel downloads
sudo sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
sudo sed -i 's/^#\(ParallelDownloads = 5\)/\1/' /etc/pacman.conf

# Synchronize time
sudo timedatectl set-ntp true

# Update mirrors and package database
sudo pacman -Syyy

# Install required utilities
sudo pacman -S fzf mdadm lvm2 git --needed --noconfirm

partprobe
sleep 2

# Disk Selection
selected_disks=$(lsblk -d -o NAME,SIZE,MODEL | grep -E '^sd|^nvme' | fzf -m | awk '{print "/dev/"$1}')

# Ensure two disks are selected for RAID
if [ "$(echo "$selected_disks" | wc -l)" -lt 2 ]; then
    echo "Select at least two disks for RAID configuration."
    exit 1
fi

# Stop any existing RAID arrays
sudo mdadm --zero-superblock --force $(for disk in $selected_disks; do echo "${disk}p2"; done)

# Wipe disks
for disk in $selected_disks; do
    sudo wipefs --all --force $disk
done

# Partition Disks
for disk in $selected_disks; do
    echo "Partitioning $disk..."
    sudo parted $disk --script mklabel gpt
    sudo parted $disk --script mkpart ESP fat32 1MiB 2049MiB
    sudo parted $disk --script set 1 esp on
    sudo parted $disk --script mkpart primary 2049MiB 100%
done

# Ensure partitions are recognized
sudo partprobe

# Create RAID-0 Array
echo "Setting up RAID-0 (striping) across selected disks"
partitions=$(for disk in $selected_disks; do echo "${disk}p2"; done)
sudo mdadm --create --verbose /dev/md0 --level=0 --raid-devices=$(echo "$selected_disks" | wc -l) $partitions

# Wait for RAID array to initialize
sleep 10

# Create Physical Volumes on RAID Array
sudo pvcreate /dev/md0

# Create Volume Group
sudo vgcreate volgroup0 /dev/md0

# Create Logical Volumes
yes | sudo lvcreate -L 130GB volgroup0 -n lv_root
yes | sudo lvcreate -L 32GB volgroup0 -n lv_swap
yes | sudo lvcreate -l 100%FREE volgroup0 -n lv_home

# Format Partitions
for disk in $selected_disks; do
    sudo mkfs.fat -F32 ${disk}p1
done
sudo mkfs.ext4 /dev/volgroup0/lv_root
sudo mkfs.ext4 /dev/volgroup0/lv_home
sudo mkswap /dev/volgroup0/lv_swap

# Mount Partitions
sudo mount /dev/volgroup0/lv_root /mnt
sudo mkdir -p /mnt/{boot/efi,home,proc,sys,dev,etc}
sudo mount $(echo $selected_disks | awk '{print $1"p1"}') /mnt/boot/efi
sudo mount /dev/volgroup0/lv_home /mnt/home
sudo swapon /dev/volgroup0/lv_swap

# Bind mount necessary filesystems
#sudo mount --bind /proc /mnt/proc
#sudo mount --bind /sys /mnt/sys
#sudo mount --bind /dev /mnt/dev

# Configure mdadm
sudo mdadm --detail --scan | sudo tee -a /mnt/etc/mdadm.conf

# Configure mkinitcpio
sudo sed -i -e 's/^HOOKS=.*$/HOOKS=(base systemd udev autodetect modconf block mdadm_udev lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
sudo cp /etc/mkinitcpio.conf /mnt/etc/mkinitcpio.conf
sudo cp /etc/pacman.conf /mnt/etc/pacman.conf

sudo pacstrap -P -K /mnt base base-devel lvm2 mdadm efibootmgr networkmanager intel-ucode \
    linux-firmware linux linux-headers git grub openssh cpupower xdg-user-dirs xdg-utils sudo nano vim

sudo genfstab -U /mnt >> /mnt/etc/fstab

# Chroot into the new system and complete configuration
sudo arch-chroot /mnt /bin/bash <<EOF
# Set up localization and timezone
echo "en_DK.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_DK.UTF-8" > /etc/locale.conf
echo "KEYMAP=dk" > /etc/vconsole.conf
ln -sf /usr/share/zoneinfo/Europe/Copenhagen /etc/localtime
hwclock --systohc
echo "governor='performance'" >> /etc/default/cpupower

systemctl enable sshd cpupower NetworkManager

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=arch_grub --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# Set hostname and hosts
echo "archlinux-desktop" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "127.0.1.1 archlinux-desktop.localdomain archlinux-desktop" >> /etc/hosts
sed -i 's/^# \(%wheel ALL=(ALL:ALL) ALL\)/\1/' /etc/sudoers
echo "heini ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers
EOF

arch-chroot /mnt /bin/bash -c 'echo "Insert root password: " && read -s root_password && echo -e "$root_password\n$root_password" | passwd'

arch-chroot /mnt useradd -m -G wheel -s /bin/bash heini

arch-chroot /mnt /bin/bash -c 'echo "Insert heini password: " && read -s heini_password && echo -e "$heini_password\n$heini_password" | passwd heini'





sudo arch-chroot /mnt /bin/bash <<'EOF'
# Create user directory and clone repositories
mkdir -p /home/heini/repos
chown -R heini:heini /home/heini/repos

# Clone repositories as user heini
su - heini -c "sudo git -C /home/heini/repos clone https://github.com/Epineph/UserScripts"
su - heini -c "sudo git -C /home/heini/repos clone https://github.com/Epineph/generate_install_command"
su - heini -c "sudo git -C /home/heini/repos clone https://github.com/JaKooLit/Arch-Hyprland"
su - heini -c "sudo git -C /home/heini/repos clone https://aur.archlinux.org/yay.git"
su - heini -c "sudo git -C /home/héini/repos clone https://aur.archlinux.org/paru.git"

# Copy scripts to /usr/local/bin
su - heini -c "sudo cp /home/heini/repos/UserScripts/log_scripts/gen_log.sh /usr/local/bin/gen_log"
su - heini -c "sudo cp /home/heini/repos/UserScripts/chPerms.sh /usr/local/bin/chPerms"

# Set permissions for /usr/local/bin
sudo chown -R heini:heini /usr/local/bin
sudo chmod -R u+rwx /usr/local/bin
echo "export PATH=/usr/local/bin:\$PATH" | tee -a /home/heini/.bashrc

# Run custom commands
su - heini -c "source /home/heini/.bashrc && sudo chPerms /home/heini/repos -R -o heini:heini -p 777 --noconfirm"
EOF

arch-chroot /mnt sudo -u heini /bin/bash -c "cd /home/heini/repos/yay && gen_log makepkg -si --noconfirm"
arch-chroot /mnt sudo -u beini /bin/bash -c "cd /home/heini/repos/paru && gen_log makepkg -si --noconfirm"
