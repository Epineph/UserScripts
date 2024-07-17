#!/bin/bash

vg_name="vg0"

# Define the logical volumes and their mount points
lv_root="/dev/mapper/$vg_name-lv_root"
lv_swap="/dev/mapper/$vg_name-lv_swap"
lv_home="/dev/mapper/$vg_name-lv_home"
mount_root="/"
mount_home="/home"

# Check space usage for each logical volume
echo "Space usage for lv_root ($lv_root):"
df -h | grep "$lv_root"

echo "Space usage for lv_swap ($lv_swap):"
free -h | grep "Swap:"

echo "Space usage for lv_home ($lv_home):"
df -h | grep "$lv_home"

echo
echo "Detailed space usage for root directory ($mount_root):"
du -sh $mount_root/* 2>/dev/null | sort -hr | head -n 10

echo
echo "Detailed space usage for home directory ($mount_home):"
du -sh $mount_home/* 2>/dev/null | sort -hr | head -n 10

