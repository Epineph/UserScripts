#!/bin/bash

# Global variables which are used throughout the script                        
# If you decide to change them, remember to change them                        
# throughout the script                                                        

USER_DIR="/home/$USER"                                                         
BUILD_DIR="$USER_DIR/builtPackages"                               
ISO_HOME="$USER_DIR/ISOBUILD/customiso"                                           
ISO_LOCATION="$ISO_HOME/ISOOUT/"                                               
AUR_HELPER_DIR="$USER_DIR/AUR-helpers"                                               

save_ISO_file() {
    # Ensure the target directory exists
    local target_dir="/home/$USER/custom_iso"
    mkdir -p "$target_dir"

    # Locate the ISO file
    local iso_file=$(find "$ISO_LOCATION" -type f -name 'archlinux-*.iso')

    # Check if the ISO file was found
    if [ -n "$iso_file" ]; then
        # Copy the ISO file to the target directory
        cp "$iso_file" "$target_dir/"
        echo "ISO file saved to $target_dir"
    else
        echo "No ISO file found in $ISO_LOCATION"
    fi
}

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


check_and_AUR() {
  local package="$1"
  local aur_helper

  # Check for AUR helper
  if type yay &>/dev/null; then
    aur_helper="yay"
  elif type paru &>/dev/null; then
    aur_helper="paru"
  else
    echo "No AUR helper found. You will need one to install AUR packages."
    read -p "Do you want to install yay? (Y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
      echo "Installing yay into $AUR_HELPER_DIR..."
      mkdir -p $AUR_HELPER_DIR && git \
      -C $AUR_HELPER_DIR clone https://aur.archlinux.org/yay.git \
      && cd $AUR_HELPER_DIR/yay && makepkg -si
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
}

pacman_packages=("archiso" "git" "base-devel")

# Loop to install each package
for pkg in "${pacman_packages[@]}"; do
    check_and_install_packages "${pkg}"
done

check_and_AUR

clone() {
    # Ensure the build directory exists
    mkdir -p "$BUILD_DIR"

    # Check if the first argument is an HTTP URL
    if [[ $1 == http* ]]; then
        # Handle AUR links
        if [[ $1 == *aur.archlinux.org* ]]; then
            # Clone the repository
            git -C "$BUILD_DIR" clone "$1"
            # Change to the repository's directory
            repo_name=$(basename "$1" .git)
            cd "$BUILD_DIR/$repo_name"

            # Build or install based on the second argument
            if [[ $2 == build ]]; then
                makepkg --skippgpcheck --noconfirm
            elif [[ $2 == install ]]; then
                makepkg -si
            fi
        else
            # Clone non-AUR links
            if [[ $1 != *".git" ]]; then
                git clone "$1.git"
            else
                git clone "$1"
            fi
        fi
    else
        # Clone GitHub repos given in the format username/repository
        git clone "https://github.com/$1.git"
    fi
}

read -p "Do you want to burn the ISO to USB after building has finished? (yes/no): " confirmation

aur_packages=("clonezilla")

# Loop to clone and build each package
for pkg in "${aur_packages[@]}"; do
    (clone "https://aur.archlinux.org/${pkg}.git" build)
done

# Ensure the ISO build directory exists
mkdir -p "$USER_DIR/ISOBUILD"

cp -r /usr/share/archiso/configs/releng $USER_DIR/ISOBUILD/

sleep 1

cd $USER_DIR/ISOBUILD

mv releng/ customiso

# Add custom packages to the ISO
custom_packages=("clonezilla")

# Append each package to the packages.x86_64 file
echo -e "\n\n#Custom Packages" | sudo tee -a "$ISO_HOME/packages.x86_64"
for pkg in "${custom_packages[@]}"; do
    echo "$pkg" | sudo tee -a "$ISO_HOME/packages.x86_64"
done

sudo chmod u+rwx $ISO_HOME/pacman.conf

# Update the pacman.conf for ParallelDownloads and multilib
sed -i "/\ParallelDownloads = 5/"'s/^#//' $ISO_HOME/pacman.conf
sed -i "/\[multilib\]/,/Include/"'s/^#//' $ISO_HOME/pacman.conf

cd $ISO_HOME

mkdir -p {WORK,ISOOUT}

(cd $ISO_HOME && sudo mkarchiso -v -w WORK -o ISOOUT .)

read -p "Do you want to save the ISO file? (yes/no): " save_confirmation

if [ "$save_confirmation" == "yes" ]; then
    save_ISO_file
else
    echo "Skipping ISO file saving."
fi

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
    # Install ddrescue if not installed
    if ! type ddrescue &>/dev/null; then
        echo "ddrescue not found. Installing it now."
        sudo pacman -S ddrescue
    fi

    # Burn the ISO to USB with ddrescue
    echo "Burning ISO to USB with ddrescue. Please wait..."
    sudo ddrescue -d -D --force "$1" "$2"
}

if [ "$confirmation" == "yes" ]; then
  locate_customISO_file
else
  echo "Exiting."
  sleep 2
  exit
fi

rm_dir() {
  for dir in "$@"
  do
    sudo rm -R "$dir"
  done
}

rm_dir $BUILD_DIR $USER_DIR/ISOBUILD
