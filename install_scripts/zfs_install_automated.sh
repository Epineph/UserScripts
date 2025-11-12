#!/bin/bash

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
EFI_PARTITION_1="/dev/nvme1n1p1"; EFI_PARTITION_2="/dev/nvme0n1p1"; EFI_PARTITION_3="/dev/sda8"
BOOT_PARTITION_1="/dev/nvme1n1p7"; BOOT_PARTITION_2="/dev/nvme0n1p6"; BOOT_PARTITION_3="/dev/sda10"
DISK_NAME_1="/dev/nvme1n1"; DISK_NAME_2="/dev/nvme0n1"; DISK_NAME_3="/dev/sda"

DISK_ARRAY="/dev/nvme1n1p6 /dev/nvme0n1p4 /dev/sda4"

mdadm --create /dev/md/boot --level=0 --raid-disks=3 --metadata=1.0 $BOOT_PARTITION_1 $BOOT_PARTITION_2 $BOOT_PARTITION_3

#sgdisk -N 1 -t 1:8300 -c 1:"Linux filesystem" /dev/md0
mkfs.ext4 /dev/md/boot



IFS=' ' read -r -a DISK_ARRAY <<< "$DISK_ARRAY"

for i in "${!DISK_ARRAY[@]}"; do
    eval "DISK$((i+1))=${DISK_ARRAY[$i]}"
done

DISK1="/dev/nvme1n1p6"
DISK2="/dev/nvme0n1p4"
DISK3="/dev/sda4"

# Now you can use $DISK1, $DISK2, etc.

zpool create -f -o ashift=12 \
    -O acltype=posixacl \
    -O relatime=on \
    -O xattr=sa \
    -O dnodesize=auto \
    -O normalization=formD \
    -O mountpoint=none \
    -O canmount=off \
    -O devices=off \
    -R /mnt $ZFS_POOL_NAME $DISK1 $DISK2 $DISK3


zfs create -o mountpoint=none -p ${SYS_ROOT}/${SYSTEM_NAME}
zfs create -o mountpoint=none ${SYS_ROOT}/${SYSTEM_NAME}/ROOT
zfs create -o mountpoint=/ ${SYS_ROOT}/${SYSTEM_NAME}/ROOT/default
zfs create -o mountpoint=/home ${SYS_ROOT}/${SYSTEM_NAME}/home
zfs create -o canmount=off -o mountpoint=/var -o xattr=sa ${SYS_ROOT}/${SYSTEM_NAME}/var
zfs create -o canmount=off -o mountpoint=/var/lib ${SYS_ROOT}/${SYSTEM_NAME}/var/lib
zfs create -o canmount=off -o mountpoint=/var/lib/systemd ${SYS_ROOT}/${SYSTEM_NAME}/var/lib/systemd
zfs create -o canmount=off -o mountpoint=/usr ${SYS_ROOT}/${SYSTEM_NAME}/usr


SYSTEM_DATASETS='var/lib/systemd/coredump var/log var/log/journal '
SYSTEM_DATASETS+='var/lib/lxc var/lib/lxd var/lib/machines var/lib/libvirt var/cache usr/local'

# for ds in ${SYSTEM_DATASETS}; do 
#     zfs create -o mountpoint=${ds} ${SYS_ROOT}/${SYSTEM_NAME}/${ds};
# done

for ds in ${SYSTEM_DATASETS}; do 
  zfs create -o mountpoint=/${SYS_ROOT}/${SYSTEM_NAME}/${ds} \
  ${SYS_ROOT}/${SYSTEM_NAME}/"${ds}"
done

#zfs create -o mountpoint=/var/log/journal -o acltype=posixacl ${SYS_ROOT}/${SYSTEM_NAME}/var/log/journal

USER_DATASETS='heini heini/local heini/config heini/cache'
for ds in ${USER_DATASETS}; do 
    zfs create -o mountpoint=/${SYS_ROOT}/${SYSTEM_NAME}/${ds} \
    ${SYS_ROOT}/${SYSTEM_NAME}/home/"${ds}"
done

#zfs create -o mountpoint=/${SYS_ROOT}/${SYSTEM_NAME}/home/heini/.local/share -o canmount=off ${SYS_ROOT}/${SYSTEM_NAME}/home/heini/.local/share
zfs create -o mountpoint=/home/heini/.local/share \
    -o canmount=off ${SYS_ROOT}/${SYSTEM_NAME}/home/heini/local/share

zfs create -o mountpoint=/home/heini/local/share/Steam \
    ${SYS_ROOT}/${SYSTEM_NAME}/home/heini/local/share/Steam
#zfs create -o mountpoint=/${SYS_ROOT}/${SYSTEM_NAME}/home/heini/.local/share/Steam ${SYS_ROOT}/${SYSTEM_NAME}/home/heini/.local/share/Steam

zfs create -o mountpoint=none ${DATA_ROOT}

DATA_DATASETS='Books Computer Personal Pictures University Workspace Reference'

for ds in ${DATA_DATASETS}; do
    zfs create -o mountpoint=/${DATA_ROOT}/${ds} ${DATA_ROOT}/"${ds}"
done

zfs allow heini create,mount,mountpoint,snapshot ${SYS_ROOT}/${SYSTEM_NAME}/home/heini

zfs allow ${SYS_ROOT}/${SYSTEM_NAME}/home/heini


zfs create -V 16G -b $(getconf PAGESIZE) -o compression=off \
    -o logbias=throughput -o sync=always -o primarycache=metadata \
    -o secondarycache=none -o com.sun:auto-snapshot=false \
    $ZFS_POOL_NAME/swap
mkswap $SWAP_VOL
swapon $SWAP_VOL


zpool export zroot

zfs umount -a

cd /mnt


rm -rf ./*

    # Duplicate boot partition to second drive    

