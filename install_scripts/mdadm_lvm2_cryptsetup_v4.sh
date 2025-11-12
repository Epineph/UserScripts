#!/bin/bash

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
if [ "$(echo "$selected_disks" | wc -l)" -lt 2]; then
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
mdadm --create --verbose /dev/md0 --level=0 --raid-devices="$(echo "$selected_disks" | wc -l)" "$partitions"

# Wait for RAID array to initialize
sleep 10

# Encrypt the RAID array with LUKS1
cryptsetup luksFormat --type luks1 /dev/md0
cryptsetup open /dev/md0 cryptraid

# Create Physical Volumes on encrypted RAID array
pvcreate /dev/mapper/cryptraid

# Create Volume Group
vgcreate volgroup0 /dev/mapper/cryptraid

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

mkdir -p /mnt/{boot/efi,home,etc}
mount "$(echo "$selected_disks" | awk '{print $1"p1"}')" /mnt/boot/efi
mount /dev/volgroup0/lv_home /mnt/home
swapon /dev/volgroup0/lv_swap

# Bind mount necessary filesystems
mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys
mount --bind /run /mnt/run
mount --make-rslave /mnt/run


sed -i 's/^HOOKS=.*$/HOOKS=(base udev microcode modconf kms keyboard keymap consolefont block  mdadm_udev lvm2 encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf

# Chroot into the new environment
chroot /mnt /bin/bash <<EOF

# Mount the efivars filesystem
mount -t efivarfs efivarfs /sys/firmware/efi/efivars

# Install required packages inside chroot
pacman -S --needed --noconfirm grub efibootmgr

# Set the cryptdevice and root parameters in /etc/default/grub
UUID=\$(blkid -s UUID -o value /dev/md0)
sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX="cryptdevice=UUID=\$UUID:cryptraid root=/dev/volgroup0/lv_root"|' /etc/default/grub
echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub

# Install GRUB to the EFI directory
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB

# Generate the GRUB configuration file
grub-mkconfig -o /boot/grub/grub.cfg

# Ensure mkinitcpio.conf has the correct hooks and keyfile
sed -i 's/^HOOKS=.*$/HOOKS=(base udev autodetect modconf block mdadm_udev lvm2 encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf

# Optional: Create a keyfile for unlocking the root partition
mkdir -p /etc/luks-keys
dd if=/dev/urandom of=/etc/luks-keys/rootkey bs=512 count=4 iflag=fullblock
chmod 000 /etc/luks-keys/rootkey
cryptsetup luksAddKey /dev/md0 /etc/luks-keys/rootkey

# Add keyfile to initramfs image
echo 'FILES=(/etc/luks-keys/rootkey)' >> /etc/mkinitcpio.conf

# Regenerate the initramfs image
mkinitcpio -P

# Update GRUB and initramfs
grub-mkconfig -o /boot/grub/grub.cfg
mkinitcpio -P

# Save RAID configuration
mdadm --detail --scan >> /etc/mdadm.conf

# Configure fstab
cat <<FSTAB >> /etc/fstab
/dev/mapper/volgroup0-lv_root  /        ext4    rw,noatime     0 1
/dev/mapper/volgroup0-lv_home  /home    ext4    defaults       0 2
UUID=$(blkid -s UUID -o value ${selected_disks[0]}p1)  /boot/efi vfat    rw,relatime,codepage=437,iocharset=iso8859-1,shortname=mixed,utf8,tz=UTC,errors=remount-ro   0 2
/dev/mapper/volgroup0-lv_swap  none     swap    defaults       0 0
FSTAB

echo "GRUB and initramfs have been configured for LUKS encryption."

EOF

# Unmount partitions and reboot
umount -R /mnt
swapoff -a
reboot





























sed -i 's/^HOOKS=.*$/HOOKS=(base udev microcode modconf kms keyboard keymap consolefont block  mdadm_udev lvm2 encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
