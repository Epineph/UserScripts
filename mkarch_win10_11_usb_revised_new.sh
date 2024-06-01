import os
import shutil
import subprocess
import sys

def check_root():
    if os.geteuid() != 0:
        print("This script must be run as root")
        sys.exit(1)

def check_installations():
    if not shutil.which("fzf"):
        print("fzf is not installed. Installing...")
        subprocess.run(["pacman", "-Sy", "fzf", "--noconfirm"], check=True)

    if not shutil.which("woeusb"):
        print("woeusb is not installed. Installing...")
        subprocess.run(["pacman", "-Sy", "woeusb", "--noconfirm"], check=True)

def select_iso():
    print("Select the ISO file:")
    iso_file = subprocess.run("find /home -type f -name '*.iso' | fzf --prompt='Choose ISO: '", 
                              shell=True, stdout=subprocess.PIPE).stdout.decode().strip()
    if not iso_file:
        print("No ISO file selected. Exiting.")
        sys.exit(1)
    return iso_file

def select_usb_device():
    print("Select the target USB device:")
    usb_device = subprocess.run("lsblk -dno NAME,SIZE,MODEL | fzf --prompt='Choose Device: ' | awk '{print $1}'", 
                                shell=True, stdout=subprocess.PIPE).stdout.decode().strip()
    if not usb_device:
        print("No USB device selected. Exiting.")
        sys.exit(1)
    return f"/dev/{usb_device}"

def main():
    check_root()
    check_installations()
    
    choice = input("Do you want to download the latest Arch Linux ISO? (y/N): ").strip().lower()
    
    if choice == 'y':
        iso_url = "https://mirrors.dotsrc.org/archlinux/iso/2024.05.01/archlinux-2024.05.01-x86_64.iso"
        iso_file = "/tmp/archlinux.iso"
        print(f"Downloading the latest Arch Linux ISO from {iso_url}...")
        subprocess.run(["curl", "-L", "-o", iso_file, iso_url], check=True)
    else:
        iso_file = select_iso()
    
    usb_device = select_usb_device()

    print(f"WARNING: All data on {usb_device} will be destroyed!")
    confirm = input("Are you sure you want to continue? (y/N): ").strip().lower()
    if confirm != 'y':
        print("Aborting.")
        sys.exit(1)
    
    subprocess.run(["woeusb", iso_file, usb_device], check=True)
    print("USB is now bootable with the provided ISO.")

if __name__ == "__main__":
    main()

