#!/bin/bash

set -e

# Install dependencies
sudo pacman -Syu --needed base-devel git cmake vulkan-headers wayland wayland-protocols


# Default values for repository and installation directories
REPOS_DIR=${REPOS_DIR:-$HOME/repos}
INSTALL_PREFIX=${INSTALL_PREFIX:-$HOME/bin}

# Create directories if they don't exist
mkdir -p $REPOS_DIR
mkdir -p $INSTALL_PREFIX

# Install dependencies
sudo pacman -Syu --needed base-devel git cmake vulkan-headers wayland wayland-protocols

# Function to clone, build, and install a repo
build_repo() {
    local repo_url=$1
    local repo_dir=$2
    local cmake_options=$3

    git clone $repo_url $REPOS_DIR/$repo_dir
    cd $REPOS_DIR/$repo_dir
    mkdir build
    cd build
    cmake .. -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX $cmake_options
    make -j$(nproc)
    make install
}

# Build Vulkan-Loader
build_repo https://github.com/KhronosGroup/Vulkan-Loader Vulkan-Loader "-DUSE_WAYLAND_WSI=ON"

# Build Vulkan-Tools
build_repo https://github.com/KhronosGroup/Vulkan-Tools Vulkan-Tools "-DUSE_WAYLAND_WSI=ON"

# Build Vulkan-ValidationLayers
build_repo https://github.com/KhronosGroup/Vulkan-ValidationLayers Vulkan-ValidationLayers "-DUSE_WAYLAND_WSI=ON"

# Build Vulkan-Headers
build_repo https://github.com/KhronosGroup/Vulkan-Headers Vulkan-Headers ""

# Build Vulkan-Extensions
build_repo https://github.com/KhronosGroup/Vulkan-ExtensionLayer Vulkan-ExtensionLayer "-DUSE_WAYLAND_WSI=ON"

# Clean up
echo "Cleaning up build directories..."
rm -rf $REPOS_DIR/*/build

echo "All Vulkan tools built and installed successfully in $INSTALL_PREFIX!"

