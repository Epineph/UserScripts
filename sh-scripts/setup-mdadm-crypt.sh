#!/usr/bin/env bash
#
# arch-install-md-luks-lvm.sh
#
# Detailed CLI installer for:
#   EFI on nvme1n1p1
#   Striped /boot LV on nvme{1,0}n1p2 (unencrypted)
#   RAID-0 swap on nvme{1,0}n1p3
#   RAID-0 → LUKS2 → LVM on nvme{1,0}n1p4
#
# Usage (from Arch live USB):
#   1. Boot the USB in UEFI mode
#   2. Ensure networking
#   3. Copy & edit this script (UUIDs must be adjusted later)
#   4. chmod +x arch-install-md-luks-lvm.sh && ./arch-install-md-luks-lvm.sh
#
# NOTE: Adjust VG/LV sizes, filesystem types, and UUIDs to your needs.

set -euo pipefail
shopt -s expand_aliases

#–– Helpers ––#
echoerr() { echo >&2 "✘ $*"; }
echoinfo() { echo "✔ $*"; }

#–– 1. Verify boot mode ––#
if [ ! -d /sys/firmware/efi ]; then
  echoerr "Not booted in UEFI mode; aborting."
  exit 1
fi
echoinfo "UEFI mode OK."

#–– 2. Partition disks (using parted) ––#
#    - nvme1n1p1: EFI
#    - nvme{1,0}n1p2,p3,p4: data
#
#    You may prefer cfdisk or gdisk interactively.
parted --script /dev/nvme1n1 \
  mklabel gpt \
  mkpart ESP fat32    1MiB      513MiB   \
  set 1 boot on        \
  mkpart primary       513MiB     5GiB     \
  mkpart primary       5GiB       25GiB    \
  mkpart primary       25GiB      100%

# Mirror partition layout to nvme0n1 (except p1):
parted --script /dev/nvme0n1 \
  mklabel gpt \
  mkpart primary 513MiB     5GiB    \
  mkpart primary 5GiB       25GiB   \
  mkpart primary 25GiB      100%

echoinfo "Partitions created. Listing layout:"
lsblk /dev/nvme1n1 /dev/nvme0n1

#–– 3. Create VG for /boot (striped LV) ––#
echoinfo "Initializing PVs for /boot VG on p2..."
pvcreate /dev/nvme1n1p2 /dev/nvme0n1p2

echoinfo "Creating striped VG 'vgboot'..."
vgcreate vgboot /dev/nvme1n1p2 /dev/nvme0n1p2

echoinfo "Creating a single LV 'boot' spanning 100% of vgboot..."
lvcreate -l +100%FREE -i2 -I64 -n boot vgboot

echoinfo "Formatting /dev/vgboot/boot as ext4..."
mkfs.ext4 /dev/vgboot/boot

#–– 4. RAID-0 swap on p3 ––#
echoinfo "Creating RAID-0 array /dev/md0 for swap..."
mdadm --create --verbose /dev/md0 \
  --level=0 --raid-devices=2 \
  /dev/nvme1n1p3 /dev/nvme0n1p3

echoinfo "Formatting /dev/md0 as swap..."
mkswap /dev/md0

#–– 5. RAID-0 + LUKS2 + LVM for root/home on p4 ––#
echoinfo "Creating RAID-0 array /dev/md1 for LUKS2..."
mdadm --create --verbose /dev/md1 \
  --level=0 --raid-devices=2 \
  /dev/nvme1n1p4 /dev/nvme0n1p4

echoinfo "Encrypting /dev/md1 with LUKS2..."
cryptsetup luksFormat --type luks2 /dev/md1

echoinfo "Opening LUKS container as 'cryptraid'..."
cryptsetup open /dev/md1 cryptraid

echoinfo "Initializing PV on /dev/mapper/cryptraid..."
pvcreate /dev/mapper/cryptraid

echoinfo "Creating VG 'vglinux' on cryptraid..."
vgcreate vglinux /dev/mapper/cryptraid

# Adjust root size as desired (here: 200 GiB)
echoinfo "Creating root LV (200 GiB) and home LV (rest)..."
lvcreate -L 200G  -i2 -I64 -n root vglinux
lvcreate -l +100%FREE -i2 -I64 -n home vglinux

echoinfo "Formatting root & home LVs..."
mkfs.ext4 /dev/vglinux/root
mkfs.ext4 /dev/vglinux/home

#–– 6. Mount filesystems ––#
echoinfo "Mounting root..."
mount /dev/vglinux/root /mnt

echoinfo "Creating & mounting boot, efi, home..."
mkdir -p /mnt/{boot,efi,home}
mount /dev/vgboot/boot     /mnt/boot
mount /dev/nvme1n1p1       /mnt/efi
mount /dev/vglinux/home    /mnt/home

echoinfo "Enabling swap..."
swapon /dev/md0

#–– 7. (Optional) Fallback swapfile ––#
echoinfo "Creating fallback swapfile (22 GiB)..."
dd if=/dev/zero of=/mnt/swapfile bs=1M count=$((22*1024)) status=progress
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
swapon /mnt/swapfile

#–– 8. Generate fstab ––#
echoinfo "Generating /etc/fstab (with UUIDs)..."
genfstab -U /mnt >> /mnt/etc/fstab

echoinfo "Pre-chroot phase complete. Entering chroot..."

arch-chroot /mnt /bin/bash <<'CHROOT_EOF'
set -euo pipefail

#–– In-chroot: 9. Configure mdadm.conf ––#
echoinfo() { echo "✔ $*"; }
echo "Scanning md arrays -> /etc/mdadm.conf"
mdadm --detail --scan >> /etc/mdadm.conf
echoinfo "mdadm.conf populated."

#–– 10. /etc/crypttab ––#
UUID=$(blkid -s UUID -o value /dev/md1)
cat > /etc/crypttab <<EOF
# <name>     <source device UUID>    <keyfile or 'none'>   <options>
cryptraid    UUID=${UUID}            none                  luks,discard
EOF
echoinfo "/etc/crypttab written."

#–– 11. mkinitcpio.conf ––#
echo "Configuring mkinitcpio hooks..."
# Backup original
cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.bak
# Overwrite HOOKS line
sed -E -i 's/^HOOKS=.*/HOOKS=(systemd autodetect modconf keyboard sd-vconsole block mdadm_udev sd-encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
echoinfo "Hooks set to: systemd autodetect modconf keyboard sd-vconsole block mdadm_udev sd-encrypt lvm2 filesystems fsck"

echoinfo "Rebuilding initramfs for all kernels..."
mkinitcpio -P

#–– 12. GRUB ––#
echoinfo "Installing & configuring GRUB..."
pacman --noconfirm -S grub efibootmgr lvm2 mdadm

# Edit /etc/default/grub
cat > /etc/default/grub <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Arch"
GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3"
GRUB_CMDLINE_LINUX="root=/dev/vglinux/root resume=/dev/md0"
GRUB_PRELOAD_MODULES="lvm mdraid09_be mdraid1x luks2 cryptodisk"
GRUB_ENABLE_CRYPTODISK=y
EOF
echoinfo "/etc/default/grub written."

# Install to EFI
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=Arch
echoinfo "GRUB EFI installer done."

# Generate config
grub-mkconfig -o /boot/grub/grub.cfg
echoinfo "GRUB config generated."

#–– 13. Final checks ––#
echoinfo "Verifying initramfs contains sd-encrypt..."
if lsinitcpio -v /boot/initramfs-linux.img | grep -q sd-encrypt; then
  echoinfo "sd-encrypt hook present."
else
  echoerr "sd-encrypt missing!"
fi

echoinfo "EFI boot entries:"
efibootmgr -v | grep -A2 Arch

echoinfo "Chroot script complete. You can exit and reboot."
exit

CHROOT_EOF

echoinfo "All done! Unmounting and rebooting..."
umount -R /mnt
swapoff -a
reboot

