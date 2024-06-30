import os
import subprocess
import shutil

# Define variables
usb_dev = "/dev/sdX"  # Replace with your USB device, e.g., /dev/sdb
iso_path = "/home/heini/Documents/Win10_22H2_EnglishInternational_x64v1.iso"  # Replace with the path to your Windows ISO
mount_dir = "/mnt/windows_iso"
usb_fat32_mount_dir = "/mnt/usb_fat32"
usb_ntfs_mount_dir = "/mnt/usb_ntfs"

def run_command(command):
    process = subprocess.Popen(command, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    stdout, stderr = process.communicate()
    if process.returncode != 0:
        raise Exception(f"Command failed: {command}\nError: {stderr.decode()}")

def prepare_usb_drive(usb_dev):
    # Unmount any mounted partitions on the USB drive
    run_command(f"umount {usb_dev}* || true")

    # Create a new GPT partition table
    run_command(f"parted {usb_dev} mklabel gpt")

    # Create a small FAT32 partition for UEFI boot
    run_command(f"parted -a opt {usb_dev} mkpart primary fat32 1MiB 512MiB")
    run_command(f"parted {usb_dev} set 1 esp on")
    run_command(f"mkfs.vfat -F 32 {usb_dev}1")

    # Create a larger NTFS partition for the Windows installation files
    run_command(f"parted -a opt {usb_dev} mkpart primary ntfs 512MiB 100%")
    run_command(f"mkfs.ntfs -f {usb_dev}2")

def mount_iso(iso_path, mount_dir):
    os.makedirs(mount_dir, exist_ok=True)
    run_command(f"mount -o loop {iso_path} {mount_dir}")

def mount_usb_partitions(usb_dev, usb_fat32_mount_dir, usb_ntfs_mount_dir):
    os.makedirs(usb_fat32_mount_dir, exist_ok=True)
    run_command(f"mount {usb_dev}1 {usb_fat32_mount_dir}")

    os.makedirs(usb_ntfs_mount_dir, exist_ok=True)
    run_command(f"mount {usb_dev}2 {usb_ntfs_mount_dir}")

def copy_files(src_dir, dst_dir):
    run_command(f"rsync -avh --progress {src_dir}/ {dst_dir}")

def make_usb_bootable(usb_fat32_mount_dir):
    # Ensure the EFI directory exists and copy the bootx64.efi file
    efi_boot_dir = os.path.join(usb_fat32_mount_dir, "efi", "boot")
    os.makedirs(efi_boot_dir, exist_ok=True)
    shutil.copy(os.path.join(mount_dir, "efi", "boot", "bootx64.efi"), efi_boot_dir)

def cleanup(mount_dir, usb_fat32_mount_dir, usb_ntfs_mount_dir):
    run_command(f"umount {mount_dir}")
    run_command(f"umount {usb_fat32_mount_dir}")
    run_command(f"umount {usb_ntfs_mount_dir}")
    os.rmdir(mount_dir)
    os.rmdir(usb_fat32_mount_dir)
    os.rmdir(usb_ntfs_mount_dir)

def create_bootable_usb(usb_dev, iso_path, mount_dir, usb_fat32_mount_dir, usb_ntfs_mount_dir):
    try:
        prepare_usb_drive(usb_dev)
        mount_iso(iso_path, mount_dir)
        mount_usb_partitions(usb_dev, usb_fat32_mount_dir, usb_ntfs_mount_dir)
        copy_files(mount_dir, usb_ntfs_mount_dir)  # Copy Windows files to NTFS partition
        make_usb_bootable(usb_fat32_mount_dir)
        print("Bootable USB created successfully.")
    except Exception as e:
        print(f"An error occurred: {e}")
    finally:
        cleanup(mount_dir, usb_fat32_mount_dir, usb_ntfs_mount_dir)

if __name__ == "__main__":
    if os.geteuid() != 0:
        raise PermissionError("Please run as root")
    
    create_bootable_usb(usb_dev, iso_path, mount_dir, usb_fat32_mount_dir, usb_ntfs_mount_dir)

