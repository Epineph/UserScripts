#!/usr/bin/env python3
import os
import subprocess
import sys

def run_command(command):
    """Run a shell command and return its output."""
    try:
        output = subprocess.check_output(command, shell=True, stderr=subprocess.STDOUT)
        return output.decode()
    except subprocess.CalledProcessError as e:
        print("Error executing command:", e.cmd)
        return e.output.decode()

def check_and_install_package(package_name):
    """Check if a Python package is installed and offer to install it if not."""
    try:
        __import__(package_name)
        print(f"{package_name} is installed.")
    except ImportError:
        print(f"{package_name} is not installed.")
        user_input = input(f"Do you want to install {package_name}? (y/n): ").strip().lower()
        if user_input == 'y':
            print("Installing package...")
            install_command = f"sudo pacman -S {package_name} --noconfirm"
            print(run_command(install_command))
        else:
            print("The package is required to run this script.")
            sys.exit(1)

check_and_install_package('python-prompt_toolkit')

from prompt_toolkit import prompt
from prompt_toolkit.completion import PathCompleter, WordCompleter

def choose_iso():
    """Let the user choose an ISO file interactively."""
    iso_completer = PathCompleter(only_directories=False, expanduser=True)
    iso_path = prompt("Enter the path to the ISO file: ", completer=iso_completer)
    return iso_path

def choose_usb_device():
    """Let the user choose a USB device interactively."""
    devices = subprocess.check_output("lsblk -dno NAME,SIZE,MODEL", shell=True).decode().splitlines()
    device_completer = WordCompleter(devices, ignore_case=True)
    usb_device = prompt("Enter the USB device path (e.g., /dev/sdx): ", completer=device_completer)
    if not usb_device.startswith("/dev/"):
        usb_device = "/dev/" + usb_device.strip()
    return usb_device

def create_bootable_usb():
    # Get user input
    iso_path = choose_iso()
    usb_device = choose_usb_device()
    partition1_size = input("Enter the size (in MB) for the first partition: ").strip()
    partition2_size = input("Enter the size (in MB) for the second partition: ").strip()

    # Partition the USB drive
    print("Partitioning the USB drive...")
    partition_command = f"echo -e 'o\\nn\\np\\n1\\n\\n+{partition1_size}M\\nn\\np\\n2\\n\\n+{partition2_size}M\\nw' | sudo fdisk {usb_device}"
    print(run_command(partition_command))

    # Format the first partition as FAT32
    print("Formatting the first partition as FAT32...")
    format_command_1 = f"sudo mkfs.fat -F 32 {usb_device}1"
    print(run_command(format_command_1))

    # Format the second partition as ext4 (or another filesystem if needed)
    print("Formatting the second partition as ext4...")
    format_command_2 = f"sudo mkfs.ext4 {usb_device}2"
    print(run_command(format_command_2))

    # Mount the first partition and ISO
    print("Mounting the first partition...")
    mount_usb_command = f"sudo mount {usb_device}1 /mnt/usb"
    print(run_command(mount_usb_command))
    print("Mounting the ISO file...")
    mount_iso_command = f"sudo mount -o loop {iso_path} /mnt/iso"
    print(run_command(mount_iso_command))

    # Copy files from the ISO to the USB
    print("Copying files from the ISO to the USB...")
    copy_files_command = "sudo cp -r /mnt/iso/* /mnt/usb/"
    print(run_command(copy_files_command))

    # Install GRUB bootloader
    print("Installing GRUB bootloader...")
    install_grub_command = f"sudo grub-install --target=i386-pc --boot-directory=/mnt/usb/boot {usb_device}"
    print(run_command(install_grub_command))

    # Generate GRUB configuration file
    print("Generating GRUB configuration file...")
    grub_cfg_command = "sudo grub-mkconfig -o /mnt/usb/boot/grub/grub.cfg"
    print(run_command(grub_cfg_command))

    # Unmount the ISO and USB
    print("Unmounting ISO and USB...")
    unmount_iso_command = "sudo umount /mnt/iso"
    unmount_usb_command = "sudo umount /mnt/usb"
    print(run_command(unmount_iso_command))
    print(run_command(unmount_usb_command))

    print("Bootable USB creation process complete!")

if __name__ == "__main__":
    create_bootable_usb()
