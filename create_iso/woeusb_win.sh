#!/bin/bash

# Ensure woeusb is installed
if ! command -v woeusb &> /dev/null; then
    echo "woeusb could not be found. Please install WoeUSB-ng."
    exit 1
fi

# Function to display usage
usage() {
    cat << EOF
Usage: $0 -m <media-disk> -i <iso-location> [-f <filesystem>] [-b] [-g] [-v]

Options:
  -m, --media-disk         The target disk for the bootable USB (e.g., /dev/sda)
  -i, --iso-location       Path to the Windows ISO file
  -f, --filesystem         Target filesystem (NTFS or FAT)
  -b, --bios-boot-flag     Workaround BIOS boot flag issue
  -g, --skip-grub          Skip GRUB installation
  -v, --verbose            Enable verbose mode
  -h, --help               Show this help message and exit
EOF
    exit 1
}

# Default options
verbose=false
filesystem="NTFS"
bios_boot_flag=false
skip_grub=false

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -m|--media-disk) media_disk="$2"; shift ;;
        -i|--iso-location) iso_location="$2"; shift ;;
        -f|--filesystem) filesystem="$2"; shift ;;
        -b|--bios-boot-flag) bios_boot_flag=true ;;
        -g|--skip-grub) skip_grub=true ;;
        -v|--verbose) verbose=true ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Validate required arguments
if [[ -z "$media_disk" || -z "$iso_location" ]]; then
    echo "Error: Media disk and ISO location are required."
    usage
fi

# Select ISO file using fzf if not provided
if [[ -z "$iso_location" ]]; then
    iso_location=$(fd --type f --extension iso | fzf --prompt="Select Windows ISO file: ")
    if [[ -z "$iso_location" ]]; then
        echo "Error: No ISO file selected."
        exit 1
    fi
fi

# Select target device using fzf if not provided
if [[ -z "$media_disk" ]]; then
    media_disk=$(lsblk -dno NAME | fzf --prompt="Select target media disk: " | awk '{print "/dev/" $1}')
    if [[ -z "$media_disk" ]]; then
        echo "Error: No target device selected."
        exit 1
    fi
fi

# Build the woeusb command
cmd="sudo $(which woeusb) --device $iso_location $media_disk --target-filesystem $filesystem"

if $verbose; then
    cmd+=" --verbose"
fi

if $bios_boot_flag; then
    cmd+=" --workaround-bios-boot-flag"
fi

if $skip_grub; then
    cmd+=" --workaround-skip-grub"
fi

# Execute the command
echo "Running command: $cmd"
eval $cmd

