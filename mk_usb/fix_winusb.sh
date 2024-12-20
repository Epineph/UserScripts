#!/usr/bin/env bash

help_message() {
cat <<EOF
format_windows_compatible.sh -- A script to create an MBR partition table
and format a disk as exFAT for maximum Windows compatibility.

Usage:
  sudo ./format_windows_compatible.sh [DEVICE]

If DEVICE is not provided, you will be prompted to select a device from a list.

Examples:
  sudo ./format_windows_compatible.sh /dev/sdb

Requirements:
  - parted
  - exfatprogs
  - fzf (for interactive device selection if no device is provided)

Warning:
  This script will destroy all data on the selected device.
EOF
}

check_and_install_packages() {
  local missing_packages=()

  # Check for missing packages
  for package in "$@"; do
    if ! pacman -Qi "$package" &>/dev/null; then
      missing_packages+=("$package")
    else
      echo "Package '$package' is already installed."
    fi
  done

  # If missing packages are found, offer to install them
  if (( ${#missing_packages[@]} )); then
    echo "The following packages are not installed: ${missing_packages[*]}"
    read -p "Install them now? [Y/n]: " -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
      if ! sudo pacman -S --noconfirm "${missing_packages[@]}"; then
        echo "Failed to install required packages. Aborting."
        exit 1
      fi
    else
      echo "These packages are required: ${missing_packages[*]}. Aborting."
      exit 1
    fi
  fi
}

command_to_package() {
  # Map commands to their corresponding packages
  # Adjust this mapping as needed
  case "$1" in
    parted) echo "parted";;
    mkfs.exfat) echo "exfatprogs";;
    fzf) echo "fzf";;
    *) return 1;;
  esac
}

check_command_or_install() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    echo "Command '$cmd' not found."
    pkg=$(command_to_package "$cmd")
    if [ -n "$pkg" ]; then
      echo "Installing package '$pkg' to provide '$cmd'..."
      check_and_install_packages "$pkg"
    else
      echo "No known package mapping for '$cmd'. Aborting."
      exit 1
    fi
  fi
}

# Check if run as root
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root." >&2
  exit 1
fi

DEVICE="$1"

if [[ "$DEVICE" == "-h" || "$DEVICE" == "--help" ]]; then
  help_message
  exit 0
fi

# If no device is provided, show help and then allow user to select device
if [ -z "$DEVICE" ]; then
  help_message
  echo
  echo "No device provided. Let's select one interactively."
fi

# Check commands before proceeding
for cmd in parted mkfs.exfat fzf; do
  check_command_or_install "$cmd"
done

if [ -z "$DEVICE" ]; then
  # List block devices
  DEVICES=$(lsblk -d -o NAME,SIZE,TYPE | grep disk | awk '{print "/dev/" $1 " (" $2 ")"}')
  if [ -z "$DEVICES" ]; then
    echo "No suitable block devices found."
    exit 1
  fi

  DEVICE_CHOICE=$(echo "$DEVICES" | fzf --prompt="Select a device: ")
  if [ -z "$DEVICE_CHOICE" ]; then
    echo "No device selected, aborting."
    exit 1
  fi

  # Extract just the /dev/sdX from the line
  DEVICE=$(echo "$DEVICE_CHOICE" | awk '{print $1}')
fi

if [ ! -b "$DEVICE" ]; then
  echo "Device $DEVICE not found. Check if it's plugged in and correct."
  exit 1
fi

read -p "This will destroy all data on $DEVICE. Are you sure? (y/N) " confirm
if [[ $confirm != "y" && $confirm != "Y" ]]; then
  echo "Aborted."
  exit 1
fi

umount "${DEVICE}"* &>/dev/null

parted -s "$DEVICE" mklabel msdos
parted -s "$DEVICE" mkpart primary exfat 0% 100%
partprobe "$DEVICE"

mkfs.exfat "${DEVICE}1" -n "WIN_COMPAT"

echo "Formatting complete. ${DEVICE}1 is now an exFAT partition."
echo "You can now plug it into a Windows system and it should be recognized."

