#!/bin/bash

# Function to get the list of packages that need to be rebuilt
get_packages_to_rebuild() {
    # Get the list of packages that appear in the upgrade list
    yay -Syyu --devel --noconfirm --needed | grep -E '^ ->' | awk '{print $2}' | sort -u
}

# Function to force rebuild AUR packages
rebuild_aur_packages() {
    # Step 1: Synchronize the package databases
    yay -Syyu --noconfirm

    # Step 2: Clean build directories and rebuild packages
    local packages=("$@")
    for package in "${packages[@]}"; do
        echo "Rebuilding package: $package"
        yay -Rns --noconfirm "$package" # Remove package and its dependencies
        yay -S --noconfirm --rebuildtree --cleanbuild "$package"
    done
}

# Function to check if the packages are still listed for an upgrade
check_upgrade_loop() {
    local packages=("$@")
    for package in "${packages[@]}"; do
        if yay -Qu | grep -q "$package"; then
            return 0
        fi
    done
    return 1
}

# Automatically configure the list of packages to rebuild
packages_to_rebuild=($(get_packages_to_rebuild))

if [ ${#packages_to_rebuild[@]} -eq 0 ]; then
    echo "No AUR packages need to be rebuilt."
    exit 0
fi

# Step 3: Rebuild packages and check for upgrade loops
rebuild_aur_packages "${packages_to_rebuild[@]}"

# Step 4: Check for upgrade loops
if check_upgrade_loop "${packages_to_rebuild[@]}"; then
    echo "Upgrade loop detected. Attempting to downgrade problematic packages..."
    for package in "${packages_to_rebuild[@]}"; do
        echo "Downgrading package: $package"
        yay -U --noconfirm --needed $(pacman -Qq | grep "^$package")
        echo "Rebuilding package: $package"
        yay -S --noconfirm --rebuildtree --cleanbuild "$package"
    done
fi

echo "All packages should be up-to-date."

