#!/bin/bash
################################################################################
# Global variables which are used throughout the script                        #
# If you decide to change them, remember to change them                        #
# throughout the script                                                        #
################################################################################
USER_DIR="/home/$USER"                                                         #
BUILD_DIR="$USER_DIR/builtPackages"                                            #
PY_URL="https://raw.githubusercontent.com/Epineph/zfsArch/main/test.py"        #
ISO_HOME="$USER_DIR/ISOBUILD/zfsiso"                                           #
ISO_LOCATION="$ISO_HOME/ISOOUT/"                                               #
ISO_FILES="$ISO_LOCATION/archlinux-*.iso"                                      #
AUR_HELPER_DIR="$AUR_HELPER_DIR"                                               #
ZFS_REPO_DIR="$ISO_HOME/zfsrepo"                                               #
GITHUB_REPOSITORY="$git_author/$repo_name"                                     #
AUR_URL="https://aur.archlinux.org"                                            #
################################################################################
# Function that checks if the needed packages are installed                    #
# If some package is missing, the user will be prompted                        #
# and asked if the packages can be installed, otherwise                        #
# the script will fail                                                         #
################################################################################

save_ISO_file() {
    # Ensure the target directory exists
    local target_dir="/home/$USER/zfs_iso"
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

################################################################################
# Function that checks if an AUR helper is installled                          #
# The user is asked to install yay if it isn't installed                       #
# An AUR-helper is needed to get the needed packages                           #
# to build the iso.                                                            #
################################################################################

(


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
      echo "Installing yay into $USER_DIR/AUR-helpers..."
      mkdir -p $USER_DIR/AUR-helpers && git \
      -C $USER_DIR/AUR-helpers clone https://aur.archlinux.org/yay.git \
      && cd $USER_DIR/AUR-helpers/yay && makepkg -si
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

pacman_packages=("archiso" "git" "python-setuptools" "python-virtualenvwrapper" "python-requests"\
 "gcc-libs" "python-beautifulsoup4" "ncurses" "util-linux-libs" "base-devel")


# Loop to clone and build each package
for pkg in "${pacman_packages[@]}"; do
    check_and_install_packages "${pkg}"
done


check_and_AUR

################################################################################
# This is a custom clone function that I have made.                            #
# There is nothing really special about it, but it allows the user to          #
# to clone packages from the AUR using 'clone <AUR_LINK> <option>'             #
# option can be either 'build' (build only) or 'install' (install pkg)         #
# The clone function can also be used for github repositories and it           #
# and can be used with the full link provided, i.e.,                           #
# 'clone https://github.com/<author>/<repo>' or 'clone <author>/<repo>'        #
# I made the function for my own convenience for another project.              #
# Feel free to use or improve it if you find it useful                         #
################################################################################

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

read -p "Do you want to burn the ISO to USB after building has finished?\
(yes/no): " confirmation

#########################################################################
# The packages included in the list 'aur_packages' will be built        #
# and added to a custom repository which the iso                        #
# will use and include in the resulting image.                          #
#########################################################################

aur_packages=("zfs-dkms" "zfs-utils" "mkinitcpio-sd-zfs"\
 "gptfdisk-git" "pacman-zfs-hook") 

# Loop to clone and build each package
for pkg in "${aur_packages[@]}"; do
    (clone "https://aur.archlinux.org/${pkg}.git" build)
done

# Ensure the ISO build directory exists


mkdir -p "$USER_DIR/ISOBUILD"

cp -r /usr/share/archiso/configs/releng $USER_DIR/ISOBUILD/

sleep 1

cd $USER_DIR/ISOBUILD

mv releng/ zfsiso



# Ensure the ZFS repository directory exists
mkdir -p "$ZFS_REPO_DIR"

cd $ZFS_REPO_DIR

# Loop to copy the built packages
for pkg in "${aur_packages[@]}"; do
    cp "$BUILD_DIR/$pkg"/*.zst .
done



sudo repo-add zfsrepo.db.tar.gz *.zst

# allowing 5 parallel downloads
sed -i "/\ParallelDownloads = 5/"'s/^#//' $ISO_HOME/pacman.conf

# uncommenting multilib
sed -i "/\[multilib\]/,/Include/"'s/^#//' $ISO_HOME/pacman.conf

custom_packages=("linux-headers" "${aur_packages[@]}")

# Append each package to the packages.x86_64 file
echo -e "\n\n#Custom Packages" | sudo tee -a "$ISO_HOME/packages.x86_64"
for pkg in "${custom_packages[@]}"; do
    echo "$pkg" | sudo tee -a "$ISO_HOME/packages.x86_64"
done

sudo chmod u+rwx $ISO_HOME/pacman.conf

url="https://archzfs.com/archzfs/x86_64/"

# Define the path to the pacman.conf file
pacman_conf="$ISO_HOME/pacman.conf"

# Export the URL so that it can be accessed as an environment variable in Python
export url

################################################################################
# Nested python script that fetches the date for the latest change             #
# made to the zfs kernels and will change the pacman.conf so that              #
# packages from the arch archive matching the date are retrieved               #
# to avoid conflicts when new kernel updates are released before zfs           #
# kernels have been update, which can cause the pc to crash                    #
# So be careful if you decide to update your kernels, and it would be          #
# wise to keep atleast one kernel that is held back from updating              #
# until you are sure that zfs has updated it as well. Refer to the URL         #
# above, which should contains this information                                #
################################################################################


# Run the Python script and capture the formatted date
formatted_date=$(python3 << 'END_PYTHON'
import os
import requests
from bs4 import BeautifulSoup
import re
from datetime import datetime
# Access the URL from the environment variable
url = os.getenv('url')
# Fetch the HTML content from the URL
response = requests.get(url)
if response.status_code != 200:
    print(f"Failed to retrieve the page, status code: {response.status_code}",
    file=sys.stderr)
    sys.exit(1)
# Parse the HTML content using BeautifulSoup
soup = BeautifulSoup(response.text, 'html.parser')
# Define the regular expression pattern for the files we're looking for
file_pattern = re.compile(r'zfs-linux-\d+.*\.zst')
# Initialize an empty list to store the dates
dates = []
# Search for the files matching the pattern
for a_tag in soup.find_all('a', href=True):
    if file_pattern.search(a_tag['href']):
        sibling_text = a_tag.next_sibling
        if sibling_text:
            parts = sibling_text.strip().split()
            date = ' '.join(parts[:2])
            dates.append((a_tag['href'], date))
# Sort the dates
dates.sort(key=lambda x: x[1], reverse=True)
# Format the most recent date
if dates:
    filename, most_recent_date = dates[0]
    # Parse the date string and reformat it
    dt = datetime.strptime(most_recent_date, "%d-%b-%Y %H:%M")
    formatted_date = dt.strftime("%Y/%m/%d")
    print(formatted_date)
else:
    print("No matching files found.", file=sys.stderr)
    sys.exit(1)
END_PYTHON
)

# Check if Python script executed successfully
if [ $? -eq 0 ]; then
    echo "Formatted Date: $formatted_date"
else
    echo "The Python script failed."
    exit 1
fi

FORMATTED_SERVER="https://archive.archlinux.org/repos/${formatted_date}/\$repo/os/\$arch"

cd $ISO_HOME



if ! grep -q "\[community\]" "$pacman_conf"; then
        sed -i "/^\[$repo\]/,/Include/ s|Include = .*|Server = https://archive.archlinux.org/repos/${formatted_date}/\$repo/os/\$arch\nSigLevel = PackageRequired|" $pacman_conf
fi

# Add the [archzfs] repository configuration if it doesn't exist
if ! grep -q "\[archzfs\]" "$pacman_conf"; then
    echo -e "\n[archzfs]\nServer = https://archzfs.com/\$repo/\$arch\nSigLevel = Optional TrustAll" >> $pacman_conf
fi

# Make the changes for [core], [extra], [multilib] and [community]
for repo in core extra multilib community; do
    sed -i "/^\[$repo\]/,/Include/ s|Include = .*|Server = https://archive.archlinux.org/repos/${formatted_date}/\$repo/os/\$arch\nSigLevel = PackageRequired|" $pacman_conf
done

sudo cp /etc/pacman.conf /etc/pacman.conf.backup

sudo cp $ISO_HOME/pacman.conf /etc/pacman.conf


sudo cp $ISO_HOME/pacman.conf $ISO_HOME/airootfs/etc/pacman.conf

sudo echo -e "\n[zfsrepo]\nSigLevel = Optional TrustAll\nServer\
= file:///home/$USER/ISOBUILD/zfsiso/zfsrepo" >> $ISO_HOME/pacman.conf

mkdir {WORK,ISOOUT}


(cd $ISO_HOME && sudo mkarchiso -v -w WORK -o ISOOUT .)


sudo cp /etc/pacman.conf.backup /etc/pacman.conf

################################################################################
# This part asks the user if the image should be burned to a usb               #
# I have also included the possibility to choose the size of the               #
# usb partitions by curling an interactive python script from my repo          #
# you have to fill out the path to the ISO                                     #
################################################################################
read -p "Do you want to save the ISO file? (yes/no): " save_confirmation

if [ "$save_confirmation" == "yes" ]; then
    save_ISO_file
else
    echo "Skipping ISO file saving."
fi




################################################################################
# This part asks the user if the image should be burned to a usb               #
# I have also included the possibility to choose the size of the               #
# usb partitions by curling an interactive python script from my repo          #
# you have to fill out the path to the ISO                                     #
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
      read -p "Enter the device name \
      (e.g., /dev/sda, /dev/nvme0n1): " device

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

)
