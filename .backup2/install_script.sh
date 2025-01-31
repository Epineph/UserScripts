#!/bin/bash

DISK1="/dev/nvme1n1"
DISK2="/dev/nvme0n1"

EFI_PARTITION1="${DISK1}p1"
EFI_PARTITION2="${DISK2}p1"
WINDOWS_PARTITION="${DISK1}p2"

LINUX_LVM_PARTITION1="${DISK1}p3"
LINUX_LVM_PARTITION2="${DISK2}p2"

mdadm --create --verbose /dev/md/ESP --level=1 --raid-devices=2 $EFI_PARTITION1 $EFI_PARTITION2

