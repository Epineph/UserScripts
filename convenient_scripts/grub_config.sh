#!/bin/bash

# Default bootloader name
BOOTLOADER_ID="GRUB"
CLONE_EFI=false
EFI_CLONE_TARGET=""
EFI_DEVICE=""
PARTITION_PROVIDED=false

# Display Help Section
function display_help() {
    cat <<EOF
Usage: $0 [options]

Options:
  -p, -P <partition>       Specify the EFI partition (e.g., /dev/nvme0n1p1).
  -c, -C [<partition>]     Clone the EFI partition for redundancy. Optionally, specify the target partition.
  -b, -B <bootloader-id>   Specify the bootloader ID (default: GRUB).
  -h, --help               Display this help message.

Examples:
  $0                       Automatically detect and prompt for EFI partitions.
  $0 -p /dev/nvme0n1p1     Install GRUB on the specified EFI partition.
  $0 -p /dev/nvme0n1p1 -c  Clone the EFI partition after installing GRUB.
EOF
}

# Function to parse arguments
function parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|-P)
                EFI_DEVICE="$2"
                PARTITION_PROVIDED=true
                shift 2
                ;;
            -c|-C|--clone-efi-across)
                CLONE_EFI=true
                if [[ "$2" =~ ^/dev/ ]]; then
                    EFI_CLONE_TARGET="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            -b|-B|--bootloader-id)
                BOOTLOADER_ID="$2"
                shift 2
                ;;
            -h|--help)
                display_help
                exit 0
                ;;
            *)
                echo "Unknown argument: $1"
                display_help
                exit 1
                ;;
        esac
    done
}

# Function to detect EFI partitions
function detect_efi_partitions() {
    lsblk -n -o PATH,FSTYPE | grep -i "vfat" | awk '{print $1}'
}

# Function to prompt user for partition selection
function prompt_for_partition() {
    local efi_partitions=("$@")
    echo "Found the following EFI partitions:"
    for i in "${!efi_partitions[@]}"; do
        echo "$((i+1))) ${efi_partitions[$i]}"
    done
    read -p "Select a partition [1-${#efi_partitions[@]}]: " selection
    EFI_DEVICE="${efi_partitions[$((selection-1))]}"
}

# Function to install GRUB
function install_grub() {
    echo "Mounting $EFI_DEVICE to /boot/efi..."
    if ! sudo mount "$EFI_DEVICE" /boot/efi; then
        echo "Error: Failed to mount $EFI_DEVICE. Exiting."
        exit 1
    fi

    echo "Installing GRUB..."
    if ! sudo grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$BOOTLOADER_ID" --recheck; then
        echo "Error: GRUB installation failed. Exiting."
        sudo umount /boot/efi
        exit 1
    fi

    sudo grub-mkconfig -o /boot/grub/grub.cfg
    sudo umount /boot/efi
    echo "Grub installation finished. Bootloader: $BOOTLOADER_ID installed on $EFI_DEVICE."
}

# Function to clone EFI partition
function clone_efi_partition() {
    echo "Cloning $EFI_DEVICE to $EFI_CLONE_TARGET..."
    if ! sudo dd if="$EFI_DEVICE" of="$EFI_CLONE_TARGET" bs=1M status=progress; then
        echo "Error: Cloning failed. Exiting."
        exit 1
    fi
    echo "EFI partition cloned successfully to $EFI_CLONE_TARGET."
}

# Main script logic
parse_args "$@"

if [[ $PARTITION_PROVIDED == false ]]; then
    efi_partitions=($(detect_efi_partitions))
    if [[ ${#efi_partitions[@]} -eq 0 ]]; then
        echo "No EFI partitions found!"
        exit 1
    elif [[ ${#efi_partitions[@]} -eq 1 ]]; then
        EFI_DEVICE="${efi_partitions[0]}"
    else
        prompt_for_partition "${efi_partitions[@]}"
    fi
fi

if [[ ! -b "$EFI_DEVICE" ]]; then
    echo "Error: $EFI_DEVICE is not a valid block device. Exiting."
    exit 1
fi

install_grub

if [[ $CLONE_EFI == true ]]; then
    if [[ -z "$EFI_CLONE_TARGET" ]]; then
        efi_partitions=($(detect_efi_partitions))
        if [[ ${#efi_partitions[@]} -gt 1 ]]; then
            echo "Select a target partition for cloning:"
            prompt_for_partition "${efi_partitions[@]}"
            EFI_CLONE_TARGET="$EFI_DEVICE"
        else
            EFI_CLONE_TARGET="${efi_partitions[1]}"
        fi
    fi

    if [[ "$EFI_DEVICE" == "$EFI_CLONE_TARGET" ]]; then
        echo "Error: Source and target partitions cannot be the same. Exiting."
        exit 1
    fi

    clone_efi_partition
fi
