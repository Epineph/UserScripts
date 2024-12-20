#!/bin/bash

# User-defined Variables
USER_NAME="heini"
ZFS_POOL_NAME="zroot"
ZFS_DATA_POOL_NAME="zfsdata"
ZFS_SYS="sys"
SYS_ROOT="${ZFS_POOL_NAME}/${ZFS_SYS}"
SYSTEM_NAME="archzfs"
DATA_STORAGE="data"
DATA_ROOT="${ZFS_POOL_NAME}/${DATA_STORAGE}"
ZVOL_DEV="/dev/zvol"
SWAP_VOL="${ZVOL_DEV}/${ZFS_POOL_NAME}/swap"

# Prompt for EFI Partitions
echo "Enter EFI partitions (space-separated, e.g., /dev/nvme1n1p1 /dev/nvme0n1p1):"
read -ra EFI_PARTITIONS
echo "Selected EFI partitions: ${EFI_PARTITIONS[@]}"

# Prompt for Boot Partitions
echo "Enter Boot partitions (space-separated, e.g., /dev/nvme1n1p7 /dev/nvme0n1p6):"
read -ra BOOT_PARTITIONS
echo "Selected Boot partitions: ${BOOT_PARTITIONS[@]}"

# RAID Setup
if [[ ${#BOOT_PARTITIONS[@]} -gt 1 ]]; then
    echo "Creating RAID-0 array for Boot partitions..."
    mdadm --create /dev/md/boot --level=0 --raid-disks=${#BOOT_PARTITIONS[@]} --metadata=1.0 "${BOOT_PARTITIONS[@]}"
    mkfs.ext4 /dev/md/boot
    BOOT_DEVICE="/dev/md/boot"
else
    echo "Using single boot partition: ${BOOT_PARTITIONS[0]}"
    mkfs.ext4 "${BOOT_PARTITIONS[0]}"
    BOOT_DEVICE="${BOOT_PARTITIONS[0]}"
fi

# Prompt for ZFS Disks
echo "Enter disks for ZFS pool (space-separated, e.g., /dev/nvme1n1p6 /dev/nvme0n1p4):"
read -ra ZFS_DISKS
echo "Selected ZFS disks: ${ZFS_DISKS[@]}"

# Create ZFS Pool
zpool create -f -o ashift=12 \
    -O acltype=posixacl \
    -O relatime=on \
    -O xattr=sa \
    -O dnodesize=auto \
    -O normalization=formD \
    -O mountpoint=none \
    -O canmount=off \
    -O devices=off \
    -R /mnt $ZFS_POOL_NAME "${ZFS_DISKS[@]}"

# ZFS Filesystems Creation
zfs create -o mountpoint=none -p ${SYS_ROOT}/${SYSTEM_NAME}
zfs create -o mountpoint=none ${SYS_ROOT}/${SYSTEM_NAME}/ROOT
zfs create -o mountpoint=/ ${SYS_ROOT}/${SYSTEM_NAME}/ROOT/default
zfs create -o mountpoint=/home ${SYS_ROOT}/${SYSTEM_NAME}/home
zfs create -o canmount=off -o mountpoint=/var -o xattr=sa ${SYS_ROOT}/${SYSTEM_NAME}/var
zfs create -o canmount=off -o mountpoint=/var/lib ${SYS_ROOT}/${SYSTEM_NAME}/var/lib
zfs create -o canmount=off -o mountpoint=/usr ${SYS_ROOT}/${SYSTEM_NAME}/usr

SYSTEM_DATASETS=('var/lib/systemd/coredump' 'var/log' 'var/log/journal' 'var/lib/lxc' 'var/lib/libvirt')
for ds in "${SYSTEM_DATASETS[@]}"; do
    zfs create -o mountpoint=/${ds} ${SYS_ROOT}/${SYSTEM_NAME}/${ds}
done

USER_DATASETS=('heini' 'heini/local' 'heini/config')
for ds in "${USER_DATASETS[@]}"; do
    zfs create -o mountpoint=/home/${ds} ${SYS_ROOT}/${SYSTEM_NAME}/home/${ds}
done

# Swap Volume
zfs create -V 16G -b $(getconf PAGESIZE) -o compression=off \
    -o logbias=throughput -o sync=always -o primarycache=metadata \
    -o secondarycache=none -o com.sun:auto-snapshot=false \
    $ZFS_POOL_NAME/swap
mkswap $SWAP_VOL
swapon $SWAP_VOL

# Export ZFS Pool
zpool export $ZFS_POOL_NAME

