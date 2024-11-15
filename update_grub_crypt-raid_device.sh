#!/bin/bash

# Function to get the UUID of a device
get_uuid() {
    local device="$1"
    blkid -s UUID -o value "$device"
}

# Function to update GRUB_CMDLINE_LINUX in /etc/default/grub
update_grub_config() {
    # Get UUIDs for each partition
    local uuid_nvme1=$(get_uuid /dev/nvme1n1p3)
    local uuid_nvme0=$(get_uuid /dev/nvme0n1p3)

    # Check if UUIDs were retrieved successfully
    if [[ -z "$uuid_nvme1" || -z "$uuid_nvme0" ]]; then
        echo "Error: Failed to retrieve UUIDs. Please check your device paths."
        exit 1
    fi

    # Append the cryptdevice parameters to GRUB_CMDLINE_LINUX
    local crypt_devices="cryptdevice=UUID=$uuid_nvme1:lvmcrypt cryptdevice=UUID=$uuid_nvme0:lvmcrypt2"

    # Backup original GRUB file
    cp /etc/default/grub /etc/default/grub.bak

    # Update GRUB_CMDLINE_LINUX in the /etc/default/grub file
    sed -i "s/^GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"$crypt_devices /" /etc/default/grub

    # Inform the user that the configuration has been updated
    echo "Updated GRUB_CMDLINE_LINUX with encrypted device options."
}

# Run the update function
update_grub_config

# Regenerate the GRUB configuration
echo "Regenerating GRUB configuration..."
grub-mkconfig -o /boot/grub/grub.cfg

# Optionally, install GRUB if needed (useful if the bootloader isn't installed yet)
# grub-install /dev/sdX  # Replace /dev/sdX with your actual device (e.g., /dev/sda)

echo "GRUB configuration updated and grub.cfg regenerated."
