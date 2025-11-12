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

check_and_install_packages archiso
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

aur_packages=("gptfdisk-git" "yay") 

# Loop to clone and build each package
for pkg in "${aur_packages[@]}"; do
    (clone "https://aur.archlinux.org/${pkg}.git" build --syncdeps)
done

# Ensure the ISO build directory exists

cd $HOME

VIRT_ENV_NAME="VirtPyEnv"

virtualenv $VIRT_ENV_NAME --system-site-packages --symlinks

source "$HOME/VirtPyEnv/bin/activate"


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



sudo repo-add zfsrepo.db.tar.gz *.zs

# Ensure the necessary packages are installed
check_and_install_packages python-prompt_toolkit python-pip fzf bat python-virtualenvwrapper

# Install required Python packages
pip install PyPDF2 prompt_toolkit

# Run the Python script as a subshell

# Ensure the ISO build directory exists
mkdir -p "$ISO_HOME/airootfs/etc"
mkdir -p "$ISO_HOME/airootfs/etc/pacman.d"

# Copy custom configuration files
cp /mnt/data/pacman.conf "$ISO_HOME/airootfs/etc/pacman.conf"
cp /mnt/data/sshd_config "$ISO_HOME/airootfs/etc/ssh/sshd_config"

# Build the ISO
cd "$ISO_HOME"
sudo mkarchiso -v -w WORK -o ISOOUT .

# Chroot into the new ISO to sign the keys
mount --bind /dev "$ISO_HOME/airootfs/dev"
mount --bind /proc "$ISO_HOME/airootfs/proc"
mount --bind /sys "$ISO_HOME/airootfs/sys"

chroot "$ISO_HOME/airootfs" /bin/bash <<EOF
pacman-key --init
pacman-key --populate


EOF

umount "$ISO_HOME/airootfs/dev"
umount "$ISO_HOME/airootfs/proc"
umount "$ISO_HOME/airootfs/sys"

echo "Custom ISO creation process complete!"
python3 - << 'END_PYTHON'
import os
import subprocess
from prompt_toolkit import prompt
from prompt_toolkit.completion import PathCompleter, WordCompleter

def run_command(command):
    try:
        output = subprocess.check_output(command, shell=True, stderr=subprocess.STDOUT)
        return output.decode()
    except subprocess.CalledProcessError as e:
        print("Error executing command:", e.cmd)
        return e.output.decode()

def choose_iso():
    iso_completer = PathCompleter(only_directories=False, expanduser=True)
    iso_path = prompt("Enter the path to the ISO file: ", completer=iso_completer)
    return iso_path

def choose_usb_device():
    devices = subprocess.check_output("lsblk -dno NAME,SIZE,MODEL", shell=True).decode().splitlines()
    device_completer = WordCompleter(devices, ignore_case=True)
    usb_device = prompt("Enter the USB device path (e.g., /dev/sdx): ", completer=device_completer)
    if not usb_device.startswith("/dev/"):
        usb_device = "/dev/" + usb_device.strip()
    return usb_device

def create_bootable_usb():
    iso_path = choose_iso()
    usb_device = choose_usb_device()
    partition1_size = input("Enter the size (in MB) for the first partition: ").strip()
    partition2_size = input("Enter the size (in MB) for the second partition: ").strip()

    print("Partitioning the USB drive...")
    partition_command = f"echo -e 'o\\nn\\np\\n1\\n\\n+{partition1_size}M\\nn\\np\\n2\\n\\n+{partition2_size}M\\nw' | sudo fdisk {usb_device}"
    print(run_command(partition_command))

    print("Formatting the first partition as FAT32...")
    format_command_1 = f"sudo mkfs.fat -F 32 {usb_device}1"
    print(run_command(format_command_1))

    print("Formatting the second partition as ext4...")
    format_command_2 = f"sudo mkfs.ext4 {usb_device}2"
    print(run_command(format_command_2))

    print("Mounting the first partition...")
    mount_usb_command = f"sudo mount {usb_device}1 /mnt/usb"
    print(run_command(mount_usb_command))
    print("Mounting the ISO file...")
    mount_iso_command = f"sudo mount -o loop {iso_path} /mnt/iso"
    print(run_command(mount_iso_command))

    print("Copying files from the ISO to the USB...")
    copy_files_command = "sudo cp -r /mnt/iso/* /mnt/usb/"
    print(run_command(copy_files_command))

    print("Installing GRUB bootloader...")
    install_grub_command = f"sudo grub-install --target=i386-pc --boot-directory=/mnt/usb/boot {usb_device}"
    print(run_command(install_grub_command))

    print("Generating GRUB configuration file...")
    grub_cfg_command = "sudo grub-mkconfig -o /mnt/usb/boot/grub/grub.cfg"
    print(run_command(grub_cfg_command))

    print("Unmounting ISO and USB...")
    unmount_iso_command = "sudo umount /mnt/iso"
    unmount_usb_command = "sudo umount /mnt/usb"
    print(run_command(unmount_iso_command))
    print(run_command(unmount_usb_command))

    print("Bootable USB creation process complete!")

create_bootable_usb()
END_PYTHON

cd $HOME 


