#!/bin/bash

# Define the encrypted devices
devices=("/dev/nvme1n1p3" "/dev/nvme0n1p3")
names=("lvmcrypt" "lvmcrypt2")

# Detect target root directory
if [[ -d /mnt/etc ]]; then
    target_root="/mnt"
else
    target_root=""
fi

# Define the target crypttab file
crypttab_file="$target_root/etc/crypttab"

# Backup the existing crypttab file (if any)
if [[ -f "$crypttab_file" ]]; then
    cp "$crypttab_file" "${crypttab_file}.bak"
    echo "Backup created: ${crypttab_file}.bak"
fi

# Write header to the crypttab file
echo "# Generated crypttab entries" > "$crypttab_file"

# Iterate over the devices and generate the crypttab entries
for i in "${!devices[@]}"; do
    device="${devices[i]}"
    name="${names[i]}"
    
    # Get the UUID of the LUKS device
    uuid=$(blkid -s UUID -o value "$device" 2>/dev/null)
    
    if [[ -n "$uuid" ]]; then
        echo "$name UUID=$uuid none luks" >> "$crypttab_file"
    else
        echo "Error: Unable to retrieve UUID for $device" >&2
    fi
done

# Confirm completion
echo "crypttab entries generated in: $crypttab_file"
