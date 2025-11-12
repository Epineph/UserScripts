#!/bin/bash




# Function to display current LV usage
display_lv_usage() {
    echo "Current Logical Volumes and Usage:"
    lvs -o +lv_size,lv_attr,lv_name,vg_name
    echo
    echo "Filesystem Usage:"
    df -hT --type=ext4 --type=xfs --type=btrfs
    echo
}

# Function to get logical volume selection using fzf
select_lv() {
    local prompt=$1
    local lv=$(lvs --noheadings -o lv_name,vg_name,lv_size | fzf --prompt="$prompt")
    echo $lv
}

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    check_sudo_perms
    exit 0
fi


if [ "$(whoami)" != "root" ]; then
    echo Script is running without sudo privileges.\
         Script will be running as root to perform necesssary\
          operations.
    sudo su -s "$0"
    exit
fi

yes | sudo pacman -S --neeeded fzf lsof strace



# Display current usage
display_lv_usage

# Select logical volume to shrink
SHRINK_LV=$(select_lv "Select the LV to shrink: ")
if [ -z "$SHRINK_LV" ]; then
    echo "No LV selected. Exiting."
    exit 1
fi
SHRINK_LV_NAME=$(echo $SHRINK_LV | awk '{print $1}')
SHRINK_VG_NAME=$(echo $SHRINK_LV | awk '{print $2}')

# Prompt for the size to shrink
read -p "Enter the size to shrink in GiB: " SHRINK_SIZE

# Select logical volume to extend
EXTEND_LV=$(select_lv "Select the LV to extend: ")
if [ -z "$EXTEND_LV" ]; then
    echo "No LV selected. Exiting."
    exit 1
fi
EXTEND_LV_NAME=$(echo $EXTEND_LV | awk '{print $1}')
EXTEND_VG_NAME=$(echo $EXTEND_LV | awk '{print $2}')

# Function to shrink the selected logical volume and filesystem
shrink_lv() {
    local lv_name=$1
    local vg_name=$2
    local size=$3
    local lv_path="/dev/${vg_name}/${lv_name}"

    echo "Attempting to shrink logical volume ${lv_path} by ${size}GiB..."

    if lsof | grep $lv_path; then
        echo "Filesystem is busy. Trying to resize online if supported..."
        if resize2fs -M $lv_path; then
            lvreduce -L -${size}G $lv_path -y
            resize2fs $lv_path
        else
            echo "Online resize not supported or failed. Please ensure the filesystem is not in use."
            exit 1
        fi
    else
        umount $lv_path
        e2fsck -f $lv_path
        resize2fs $lv_path $(($(blockdev --getsize64 $lv_path) / 1024 / 1024 / 1024 - size))G
        lvreduce -L -${size}G $lv_path -y
        mount $lv_path
    fi
}

# Function to extend the selected logical volume and filesystem
extend_lv() {
    local lv_name=$1
    local vg_name=$2
    local size=$3
    local lv_path="/dev/${vg_name}/${lv_name}"

    echo "Extending logical volume ${lv_path} by ${size}GiB..."
    lvextend -L +${size}G $lv_path -r -y
}

# Perform the resize operations
shrink_lv $SHRINK_LV_NAME $SHRINK_VG_NAME $SHRINK_SIZE
extend_lv $EXTEND_LV_NAME $EXTEND_VG_NAME $SHRINK_SIZE

echo "Resize operations completed successfully."
