#!/bin/bash

# Initialize default values
default_EFI_directory="/boot/efi"
exclude_dirs=("BOOT" "Linux" "Windows" "systemd" "Microsoft")
partial_matches=(".backup") # Example partial match
exact_matches=("BOOT") # Example exact match
default_bootloader_ID="GRUB"
machine_kernel_bit=$(getconf LONG_BIT)
machine_architecture=$(uname -m)

list_efi_bootloaders() {
    local efi_dir="$default_EFI_directory"

    echo "Checking EFI directory: $efi_dir"

    if [[ -d "$efi_dir/EFI" ]]; then
        echo "EFI directory exists. Listing bootloaders excluding known directories..."

        # Find directories and exclude known non-bootloader entries
        local bootloaders=$(find "$efi_dir/EFI" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | grep -vE "^($(IFS="|"; echo "${exclude_dirs[*]}"))$" | grep -vE "$(IFS="|"; echo "${partial_matches[*]}")")

        if [[ -n "$bootloaders" ]]; then
            echo "Bootloaders found in EFI directory:"
            echo "$bootloaders"
        else
            echo "No bootloader IDs found in EFI directory."
        fi
    else
        echo "EFI directory does not exist."
    fi
}

# Main script logic
if [[ $# -eq 0 ]]; then
    echo "No arguments provided."
    echo "Default bootloader-id: $default_bootloader_ID"
    echo "Your Linux kernel uses $machine_kernel_bit bit."
    echo "System architecture: $machine_architecture"
    
    list_efi_bootloaders
    
    echo -n "Do you want to use the following defaults? [y/N]: "
    read -r response
    if [[ $response =~ ^[Yy]$ ]]; then
        echo "Using system defaults."
    else
        echo "Operation cancelled."
        exit 1
    fi
else
    echo "Argument processing not shown for brevity."
fi

