#!/bin/bash

# Path to makepkg.conf
MAKEPKG_CONF="/etc/makepkg.conf"

# Backup the original makepkg.conf
sudo cp $MAKEPKG_CONF ${MAKEPKG_CONF}.bak

# Function to update or add a line in makepkg.conf
update_or_add_line() {
    local config_file=$1
    local setting=$2
    local value=$3

    if grep -q "^${setting}" "$config_file"; then
        sudo sed -i "s|^${setting}.*|${setting}=${value}|" "$config_file"
    else
        echo "${setting}=${value}" | sudo tee -a "$config_file" > /dev/null
    fi
}

# Update or add MAKEFLAGS and OPTIONS in makepkg.conf
update_or_add_line $MAKEPKG_CONF "MAKEFLAGS" "\"-j\$(nproc)\""
update_or_add_line $MAKEPKG_CONF "OPTIONS" "(!strip !docs !libtool !staticlibs !emptydirs !zipman !purge !upx !lto !debug !check)"

echo "makepkg.conf has been updated and backed up as makepkg.conf.bak."
