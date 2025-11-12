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


# Pacstrap base system
pacstrap -P -K /mnt base base-devel lvm2 mdadm linux linux-headers nvidia nvidia-settings nvidia-utils linux-firmware intel-ucode efibootmgr networkmanager xdg-user-dirs xdg-utils sudo nano vim mtools dosfstools java-runtime python-setuptools ntfs-3g archinstall archiso arch-install-scripts openssh git grub cpupower

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

# Configure cpupower
echo "governor='performance'" | tee -a /etc/default/cpupower

# Enable services
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable cpupower

# Configure sshd
sed -i 's/^#Port 22/Port 22/' /etc/ssh/sshd_config
sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#AllowAgentForwarding yes/AllowAgentForwarding yes/' /etc/ssh/sshd_config
sed -i 's/^#AllowTcpForwarding yes/AllowTcpForwarding yes/' /etc/ssh/sshd_config
sed -i 's/^#GatewayPorts no/GatewayPorts yes/' /etc/ssh/sshd_config
sed -i 's/^#X11Forwarding no/X11Forwarding yes/' /etc/ssh/sshd_config
sed -i 's/^#PermitTTY yes/PermitTTY yes/' /etc/ssh/sshd_config
sed -i 's/^#TCPKeepAlive yes/TCPKeepAlive yes/' /etc/ssh/sshd_config
sed -i 's/^#PermitUserEnvironment no/PermitUserEnvironment yes/' /etc/ssh/sshd_config
sed -i 's/^#PermitTunnel no/PermitTunnel yes/' /etc/ssh/sshd_config

# Install and configure GRUB
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=arch_grub --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# Set root password interactively
sudo -u root /bin/bash -c 'echo "Insert root password: " && read -s root_password && echo -e "$root_password\n$root_password" | passwd root'

# Set password for user heini interactively
sudo -u root /bin/bash -c 'echo "Insert heini password: " && read -s heini_password && echo -e "$heini_password\n$heini_password" | passwd heini'

EOF

# Switch to user heini and set up repositories
arch-chroot /mnt /bin/bash <<'EOSU'
su - heini <<'EOC'

# Create directories and clone repositories
mkdir -p ~/repos
cd ~/repos
git clone https://aur.archlinux.org/yay.git
git clone https://aur.archlinux.org/paru.git
git clone https://github.com/JaKooLit/Arch-Hyprland
git clone https://github.com/Epineph/UserScripts
git clone https://github.com/Epineph/generate_install_command

# Change ownership and permissions for the repos
sudo chown -R heini: ~/repos
sudo chmod -R u+rwx ~/repos

# Copy script to /usr/local/bin
sudo cp ~/repos/UserScripts/gen_log.sh /usr/local/bin/gen_log
echo "export PATH=/usr/local/bin:\$PATH" | sudo tee -a ~/.bashrc
source ~/.bashrc
sudo chown -R heini: /usr/local/bin
sudo chmod -R u+rwx /usr/local/bin

# Build and install yay
cd yay
gen_log makepkg -si --noconfirm
cd ..

# Build and install paru
cd paru
gen_log makepkg -si --noconfirm
cd ..

# Configure Arch-Hyprland
cd Arch-Hyprland
sed -i 's/pokemon_choice="Y"/pokemon_choice="N"/' preset.sh
gen_log ./install.sh
cd ..

# Output completion log
echo "Output has been logged to: ~/repos/generate_install_command/output_1.txt"
EOC
EOSU

echo "Setup is complete. Reboot your system to apply the changes."
