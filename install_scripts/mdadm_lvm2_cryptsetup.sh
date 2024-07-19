#!/bin/bash

MDADM_PATH="/dev/md0"
LVM_VG_NAME="vg0"

# Enable multilib repository
sudo sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
sudo sed -i 's/^#\(ParallelDownloads = 5\)/\1/' /etc/pacman.conf

# Synchronize time
timedatectl set-ntp true

# Update mirrors and package database
pacman -Syyy

# Install required utilities
pacman -S fzf mdadm lvm2 cryptsetup --needed --noconfirm

# Disk Selection
selected_disks=$(lsblk -d -o NAME,SIZE,MODEL | grep -E '^sd|^nvme' | fzf -m | awk '{print "/dev/"$1}')

# Ensure two disks are selected for RAID
if [ "$(echo "$selected_disks" | wc -l)" -lt 2 ]; then
    echo "Select at least two disks for RAID configuration."
    exit 1
fi

# Stop any existing RAID arrays
mdadm --zero-superblock --force "$(for disk in $selected_disks; do echo "${disk}p2"; done)"

# Wipe disks
for disk in $selected_disks; do
    wipefs --all --force "$disk"
done

# Partition Disks
for disk in $selected_disks; do
    echo "Partitioning $disk..."
    parted "$disk" --script mklabel gpt
    parted "$disk" --script mkpart ESP fat32 1MiB 2049MiB
    parted "$disk" --script set 1 esp on
    parted "$disk" --script mkpart primary 2049MiB 100%
done

# Ensure partitions are recognized
partprobe

# Create RAID-0 Array
echo "Setting up RAID-0 (striping) across selected disks"
partitions=$(for disk in $selected_disks; do echo "${disk}p2"; done)


mdadm --create --verbose $MDADM_PATH --level=0 --raid-devices="$(echo "$selected_disks" | wc -l)" "$partitions"

# Wait for RAID array to initialize
sleep 10

# Encrypt the RAID array
cryptsetup luksFormat $MDADM_PATH
cryptsetup open $MDADM_PATH cryptraid

# Create Physical Volumes on encrypted RAID array
pvcreate /dev/mapper/cryptraid

# Create Volume Group
vgcreate $LVM_VG_NAME /dev/mapper/cryptraid

# Create Logical Volumes
yes | lvcreate -L 130GB $LVM_VG_NAME -n lv_root
yes | lvcreate -L 32GB $LVM_VG_NAME -n lv_swap
yes | lvcreate -l 100%FREE $LVM_VG_NAME -n lv_home

# Format Partitions
for disk in $selected_disks; do
    mkfs.fat -F32 ${disk}p1
done
mkfs.ext4 /dev/$LVM_VG_NAME/lv_root
mkfs.ext4 /dev/$LVM_VG_NAME/lv_home
mkswap /dev/$LVM_VG_NAME/lv_swap

# Mount Partitions
mount /dev/$LVM_VG_NAME/lv_root /mnt

mkdir -p /mnt/{boot/efi,home,etc}
mount "$(echo "$selected_disks" | awk '{print $1"p1"}')" /mnt/boot/efi
mount /dev/$LVM_VG_NAME/lv_home /mnt/home
swapon /dev/$LVM_VG_NAME/lv_swap

# Configure mdadm
mdadm --detail --scan | tee -a /mnt/etc/mdadm.conf

# Configure mkinitcpio
sudo sed -i 's/^HOOKS=.*$/HOOKS=(base udev autodetect modconf block mdadm_udev lvm2 encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf

cp /etc/mkinitcpio.conf /mnt/etc/mkinitcpio.conf
cp /etc/pacman.conf /mnt/etc/pacman.conf

gen_log sudo pacstrap -P -K /mnt base base-devel lvm2 mdadm linux linux-headers nvidia-dkms nvidia-settings nvidia-utils linux-firmware intel-ucode cpupower efibootmgr networkmanager xdg-user-dirs xdg-utils sudo nano vim mtools dosfstools java-runtime python-setuptools ntfs-3g archinstall archiso arch-install-scripts lib32-vulkan-nouveau lib32-primus_vk lib32-opencl-nvidia lib32-nvidia-utils lib32-nvidia-cg-toolkit lib32-libvdpau python-pycuda python-cuda primus_vk opencl-nvidia nvidia-prime nvidia-container-toolkit nvidia-cg-toolkit nccl libxnvctrl libvdpau libva-nvidia-driver libnvidia-container ffnvcodec-headers egl-wayland cudnn cuda-tools cuda bumblebee git grub openssh cryptsetup volume_key  lib32-openssl lib32-libxcrypt-compat lib32-libxcrypt lib32-libsodium lib32-libgpg-error lib32-libgcrypt15 lib32-libgcrypt yubikey-full-disk-encryption xxhash rage-encryption python-volume_key python-securesystemslib python-scrypt python-python-pkcs11 python-pycryptodome python-m2crypto python-securesystemslib perl-cryptx perl-crypt-ssleay perl-crypt-smbhash perl-crypt-simple perl-crypt-passwdmd5 perl-crypt-openssl-rsa perl-crypt-openssl-random perl-crypt-des libmcrypt libgcrypt15 libcryptui git-crypt gpg-crypter dnscrypt-proxy  dnscrypt-wrapper firefox-extension-mailvelope fscrypt gambas3-gb-crypt crypto++ openssl-1.1 aws-c-cal libxcrypt-compat libxcrypt libgpg-error libgcrypt python-scikit-build-core python-cmake-build-extension icmake extra-cmake-modules cmake 

sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX="cryptdevice=/dev/md0:cryptraid root=/dev/$LVM_VG_NAME/lv_root"|' /mnt/etc/default/grub

echo "governor='performance'" | sudo tee -a /mnt/etc/default/cpupower

sleep 2


genfstab -U /mnt >> /mnt/etc/fstab
