#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

################################################################################
# Global variables which are used throughout the script
################################################################################
USER_DIR="/home/$USER"
BUILD_DIR="$USER_DIR/builtPackages"
ISO_HOME="$USER_DIR/ISOBUILD/customiso"
ISO_LOCATION="$ISO_HOME/ISOOUT/"
ISO_FILES="$ISO_LOCATION/archlinux-*.iso"
ZFS_REPO_DIR="$ISO_HOME/zfsrepo"
ZFS_KEY="F75D9D76"  # Example ZFS repository key, replace with actual key

################################################################################
# Function to save the ISO file to a specific directory
################################################################################
save_ISO_file() {
    local target_dir="/home/$USER/custom_iso"
    mkdir -p "$target_dir"
    local iso_file=$(find "$ISO_LOCATION" -type f -name 'archlinux-*.iso')
    if [ -n "$iso_file" ]; then
        cp "$iso_file" "$target_dir/"
        echo "ISO file saved to $target_dir"
    else
        echo "No ISO file found in $ISO_LOCATION"
    fi
}

################################################################################
# Function to check and install necessary packages using pacman
################################################################################
check_and_install_packages() {
    local missing_packages=()
    for package in "$@"; do
        if ! pacman -Qi "$package" &> /dev/null; then
            missing_packages+=("$package")
        else
            echo "Package '$package' is already installed."
        fi
    done
    if [ ${#missing_packages[@]} -ne 0 ]; then
        echo "The following packages are not installed: ${missing_packages[*]}"
        read -p "Do you want to install them? (Y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
            for package in "${missing_packages[@]}"; do
                yes | sudo pacman -S "$package"
                if [ $? -ne 0 ]; then
                    echo "Failed to install $package. Aborting."
                    exit 1
                fi
            done
        else
            echo "The following packages are required to continue: ${missing_packages[*]}. Aborting."
            exit 1
        fi
    fi
}

################################################################################
# Function to check and install an AUR helper (yay or paru)
################################################################################
check_and_install_AUR_helper() {
    local aur_helper
    if type yay &>/dev/null; then
        aur_helper="yay"
    elif type paru &>/dev/null; then
        aur_helper="paru"
    else
        echo "No AUR helper found. You will need one to install AUR packages."
        read -p "Do you want to install yay? (Y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
            echo "Installing yay into $USER_DIR/AUR-helpers..."
            mkdir -p $USER_DIR/AUR-helpers && git -C $USER_DIR/AUR-helpers clone https://aur.archlinux.org/yay.git && cd $USER_DIR/AUR-helpers/yay && makepkg -si
            cd -  # Return to the previous directory
            if [ $? -ne 0 ]; then
                echo "Failed to install yay. Aborting."
                exit 1
            else
                aur_helper="yay"
            fi
        else
            echo "An AUR helper is required to install AUR packages. Aborting."
            exit 1
        fi
    fi
    echo "AUR helper $aur_helper is installed."
}

################################################################################
# Function to clone and build AUR packages
################################################################################
clone_and_build_aur_packages() {
    local build_dir="$BUILD_DIR"
    mkdir -p "$build_dir"
    for pkg in "$@"; do
        git -C "$build_dir" clone "https://aur.archlinux.org/${pkg}.git"
        cd "$build_dir/$pkg"
        makepkg -si --noconfirm
        cd -  # Return to the previous directory
    done
}

################################################################################
# Function to configure pacman.conf for the custom ISO
################################################################################
configure_pacman_conf() {
    local iso_home="$1"
    local formatted_date="$2"
    local pacman_conf="$iso_home/pacman.conf"

    sed -i "/\[multilib\]/,/Include/ s/^#//" "$pacman_conf"
    sed -i "/ParallelDownloads = 5/ s/^#//" "$pacman_conf"

    for repo in core extra multilib community; do
        sed -i "/^\[$repo\]/,/Include/ s|Include = .*|Server = https://archive.archlinux.org/repos/${formatted_date}/\$repo/os/\$arch\nSigLevel = PackageRequired|" "$pacman_conf"
    done

    if ! grep -q "\[archzfs\]" "$pacman_conf"; then
        echo -e "\n[archzfs]\nServer = https://archzfs.com/\$repo/\$arch\nSigLevel = Optional TrustAll" >> "$pacman_conf"
    fi
}

################################################################################
# Function to add custom packages to the ISO build
################################################################################
add_custom_packages() {
    local iso_home="$1"
    shift
    local packages=("$@")

    echo -e "\n\n#Custom Packages" | sudo tee -a "$iso_home/packages.x86_64"
    for pkg in "${packages[@]}"; do
        echo "$pkg" | sudo tee -a "$iso_home/packages.x86_64"
    done
}

################################################################################
# Function to import and sign keys for the ZFS repository
################################################################################
manage_zfs_keys() {
    local key="$1"
    sudo pacman-key --recv-keys "$key"
    sudo pacman-key --lsign-key "$key"
    sudo cp /etc/pacman.d/gnupg/pubring.gpg "$ISO_HOME/airootfs/etc/pacman.d/gnupg/pubring.gpg"
    sudo cp /etc/pacman.d/gnupg/trustdb.gpg "$ISO_HOME/airootfs/etc/pacman.d/gnupg/trustdb.gpg"
}

################################################################################
# Main script execution starts here
################################################################################
pacman_packages=("archiso" "git" "python-setuptools" "python-virtualenvwrapper" "python-requests" \
"gcc-libs" "python-beautifulsoup4" "ncurses" "util-linux-libs" "base-devel" "syslinux")
aur_packages=("yay" "paru" "zfs-dkms" "zfs-utils" "mkinitcpio-sd-zfs" "gptfdisk-git" "pacman-zfs-hook" "fd" "bat" "ninja" "cmake" "re2c")

check_and_install_packages "${pacman_packages[@]}"
check_and_install_AUR_helper

clone_and_build_aur_packages "${aur_packages[@]}"

mkdir -p "$USER_DIR/ISOBUILD"
cp -r /usr/share/archiso/configs/releng "$USER_DIR/ISOBUILD/"
mv "$USER_DIR/ISOBUILD/releng" "$ISO_HOME"

mkdir -p "$ZFS_REPO_DIR"
cd "$ZFS_REPO_DIR"
for pkg in "${aur_packages[@]}"; do
    cp "$BUILD_DIR/$pkg"/*.zst .
done
sudo repo-add zfsrepo.db.tar.gz *.zst

# Fetch the date for the latest change made to the zfs kernels
url="https://archzfs.com/archzfs/x86_64/"
formatted_date=$(python3 << 'END_PYTHON'
import os
import requests
from bs4 import BeautifulSoup
import re
from datetime import datetime

url = "https://archzfs.com/archzfs/x86_64/"
response = requests.get(url)
soup = BeautifulSoup(response.text, 'html.parser')
file_pattern = re.compile(r'zfs-linux-\d+.*\.zst')
dates = []

for a_tag in soup.find_all('a', href=True):
    if file_pattern.search(a_tag['href']):
        sibling_text = a_tag.next_sibling
        if sibling_text:
            parts = sibling_text.strip().split()
            date = ' '.join(parts[:2])
            dates.append((a_tag['href'], date))

dates.sort(key=lambda x: x[1], reverse=True)
if dates:
    filename, most_recent_date = dates[0]
    dt = datetime.strptime(most_recent_date, "%d-%b-%Y %H:%M")
    formatted_date = dt.strftime("%Y/%m/%d")
    print(formatted_date)
END_PYTHON
)

configure_pacman_conf "$ISO_HOME" "$formatted_date"
add_custom_packages "$ISO_HOME" "linux-headers" "${pacman_packages[@]}" "${aur_packages[@]}"

# Import and sign the ZFS repository key
manage_zfs_keys "$ZFS_KEY"

sudo cp /etc/pacman.conf /etc/pacman.conf.backup
sudo cp "$ISO_HOME/pacman.conf" /etc/pacman.conf
sudo cp "$ISO_HOME/pacman.conf" "$ISO_HOME/airootfs/etc/pacman.conf"

echo -e "\n[zfsrepo]\nSigLevel = Optional TrustAll\nServer = file:///home/$USER/ISOBUILD/customiso/zfsrepo" >> "$ISO_HOME/pacman.conf"

mkdir -p "$ISO_HOME/WORK" "$ISO_HOME/ISOOUT"

(cd "$ISO_HOME" && sudo mkarchiso -v -w WORK -o ISOOUT .)

sudo cp /etc/pacman.conf.backup /etc/pacman.conf

read -p "Do you want to save the ISO file? (yes/no): " save_confirmation
if [ "$save_confirmation" == "yes" ]; then
    save_ISO_file
else
    echo "Skipping ISO file saving."
fi

read -p "Do you want to burn the ISO to USB after building has finished? (yes/no): " confirmation
if [ "$confirmation" == "yes" ]; then
    locate_customISO_file
else
    echo "Exiting."
    sleep 2
    exit
fi

rm_dir() {
    for dir in "$@"; do
        sudo rm -R "$dir"
    done
}

rm_dir "$BUILD_DIR" "$USER_DIR/ISOBUILD"

################################################################################
# Helper functions to list devices and burn ISO to USB
################################################################################
list_devices() {
    echo "Available devices:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
}

locate_customISO_file() {
    local ISO_LOCATION="$ISO_HOME/ISOOUT/"
    local ISO_FILES="$ISO_LOCATION/archlinux-*.iso"

    for f in $ISO_FILES; do
        if [ -f "$f" ]; then
            list_devices
            read -p "Enter the device name (e.g., /dev/sda, /dev/nvme0n1): " device

            if [ -b "$device" ]; then
                burnISO_to_USB "$f" "$device"
            else
                echo "Invalid device name."
            fi
        fi
    done
}

burnISO_to_USB() {
    if ! type ddrescue &>/dev/null; then
        echo "ddrescue not found. Installing it now."
        sudo pacman -S ddrescue
    fi
    echo "Burning ISO to USB with ddrescue. Please wait..."
    sudo ddrescue -d -D --force "$1" "$2"
}
