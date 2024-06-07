#!/bin/bash

################################################################################
# Global variables                                                            #
################################################################################
USER_DIR="/home/$USER"
ISO_HOME="$USER_DIR/ISOBUILD/customiso"
ISO_LOCATION="$ISO_HOME/ISOOUT/"
BUILD_DIR="$USER_DIR/builtPackages"

################################################################################
# Function that checks if the needed packages are installed                    #
# If some package is missing, the user will be prompted                        #
# and asked if the packages can be installed, otherwise                        #
# the script will fail                                                         #
################################################################################
check_and_install_packages() {
  local missing_packages=()

  # Check which packages are not installed
  for package in "$@"; do
    if ! pacman -Qi "$package" &> /dev/null; then
      missing_packages+=("$package")
    else
      echo "Package '$package' is already installed."
    fi
  done

  # If there are missing packages, ask the user if they want to install them
  if [ ${#missing_packages[@]} -ne 0 ]; then
    echo "The following packages are not installed: ${missing_packages[*]}"
    read -p "Do you want to install them? (Y/n) " -n 1 -r
    echo    # Move to a new line
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
      for package in "${missing_packages[@]}"; do
        yes | sudo pacman -S "$package"
        if [ $? -ne 0 ]; then
          echo "Failed to install $package. Aborting."
          exit 1
        fi
      done
    else
      echo "The following packages are required to continue:\
      ${missing_packages[*]}. Aborting."
      exit 1
    fi
  fi
}

################################################################################
# Check and install required packages                                          #
################################################################################
pacman_packages=("archiso" "git" "base-devel" "ddrescue")

# Loop to check and install each package
for pkg in "${pacman_packages[@]}"; do
    check_and_install_packages "${pkg}"
done

################################################################################
# Ensure the ISO build directory exists                                        #
################################################################################
mkdir -p "$USER_DIR/ISOBUILD"
cp -r /usr/share/archiso/configs/releng $USER_DIR/ISOBUILD/
cd $USER_DIR/ISOBUILD
mv releng/ customiso

# Allowing 5 parallel downloads and uncommenting multilib in pacman.conf
sed -i "/ParallelDownloads = 5/s/^#//" $ISO_HOME/pacman.conf
sed -i "/\[multilib\]/,/Include/s/^#//" $ISO_HOME/pacman.conf

# Ensure custom configurations are in place
# Custom pacman.conf
mkdir -p $ISO_HOME/airootfs/etc
cp /etc/pacman.conf $ISO_HOME/airootfs/etc/pacman.conf

# Custom sshd_config
mkdir -p $ISO_HOME/airootfs/etc/ssh
cp /path/to/your/sshd_config $ISO_HOME/airootfs/etc/ssh/sshd_config

# Custom packages
custom_packages=("vim" "htop")

# Append each package to the packages.x86_64 file
echo -e "\n\n#Custom Packages" | sudo tee -a "$ISO_HOME/packages.x86_64"
for pkg in "${custom_packages[@]}"; do
    echo "$pkg" | sudo tee -a "$ISO_HOME/packages.x86_64"
done

################################################################################
# Build the ISO                                                                #
################################################################################
mkdir -p $ISO_HOME/{WORK,ISOOUT}
(cd $ISO_HOME && sudo mkarchiso -v -w WORK -o ISOOUT .)

################################################################################
# Chroot into the ISO's root filesystem to run pacman-key                      #
################################################################################
sudo mount -o bind /dev $ISO_HOME/airootfs/dev
sudo mount -o bind /run $ISO_HOME/airootfs/run
sudo mount -o bind /sys $ISO_HOME/airootfs/sys
sudo mount -t proc /proc $ISO_HOME/airootfs/proc

sudo chroot $ISO_HOME/airootfs /bin/bash -c "pacman-key --init && pacman-key --populate archlinux"

# Unmount filesystems
sudo umount $ISO_HOME/airootfs/dev
sudo umount $ISO_HOME/airootfs/run
sudo umount $ISO_HOME/airootfs/sys
sudo umount $ISO_HOME/airootfs/proc

################################################################################
# Save ISO file                                                                #
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

read -p "Do you want to save the ISO file? (yes/no): " save_confirmation
if [ "$save_confirmation" == "yes" ]; then
    save_ISO_file
else
    echo "Skipping ISO file saving."
fi

################################################################################
# Burn ISO to USB                                                              #
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
        burnISO_to_USB "$f" "$device"  # Burn the ISO to USB
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

read -p "Do you want to burn the ISO to USB after building has finished? (yes/no): " confirmation
if [ "$confirmation" == "yes" ]; then
  locate_customISO_file
else
  echo "Exiting."
  sleep 2
  exit
fi

################################################################################
# Cleanup                                                                      #
################################################################################
rm -rf $BUILD_DIR $USER_DIR/ISOBUILD
