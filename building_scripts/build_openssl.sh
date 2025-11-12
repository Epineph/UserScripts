#!/bin/bash

# Define variables
OPENSSL_VERSION="3.0.2"  # You can change this to the desired OpenSSL version
INSTALL_DIR="$HOME/bin"
BUILD_DIR="$HOME/openssl_build_dir"
SOURCE_DIR="$HOME/openssl_src"
TOOLCHAIN_FILE="/home/heini/repos/vcpkg/scripts/buildsystems/vcpkg.cmake"

# Install dependencies (if not already installed)
sudo pacman -Syu --needed --noconfirm base-devel cmake git

# Create necessary directories
mkdir -p $INSTALL_DIR
mkdir -p $BUILD_DIR
mkdir -p $SOURCE_DIR

# Download OpenSSL source code
cd $SOURCE_DIR
if [ ! -d "openssl-$OPENSSL_VERSION" ]; then
    curl -O https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz
    tar -xvzf openssl-$OPENSSL_VERSION.tar.gz
fi

# Navigate to the source directory
cd openssl-$OPENSSL_VERSION

# Configure the build
cmake -B $BUILD_DIR -S . \
      -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
      -DCMAKE_TOOLCHAIN_FILE=$TOOLCHAIN_FILE \
      -DOPENSSL_USE_STATIC_LIBS=ON \
      -DOPENSSL_PIC=ON \
      -DCMAKE_BUILD_TYPE=Release

# Build and install OpenSSL
cmake --build $BUILD_DIR --target install -- -j$(nproc)

# Output information
echo "OpenSSL has been successfully built and installed to $INSTALL_DIR"

# Clean up
# Optionally remove build and source directories to save space
# rm -rf $BUILD_DIR
# rm -rf $SOURCE_DIR

