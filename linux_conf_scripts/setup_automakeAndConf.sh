#!/bin/bash

# Function to install wget and curl
install_wget_curl() {
    if [[ -f /etc/arch-release ]]; then
        echo "Arch Linux detected."
        sudo pacman -S wget curl --noconfirm
    elif [[ -f /etc/debian_version ]]; then
        echo "Debian/Ubuntu-based system detected."
        sudo apt-get install wget curl -y
    else
        echo "Unsupported distribution. Please install wget and curl manually."
        exit 1
    fi
}

# Check if wget or curl is installed
if ! command -v wget &> /dev/null && ! command -v curl &> /dev/null; then
    echo "Neither wget nor curl is installed."
    read -p "Do you want to install them? (Y/n): " install_choice
    if [[ "$install_choice" =~ ^([nN][oO]|[nN])$ ]]; then
        echo "wget and curl are required for this script. Exiting."
        exit 1
    else
        install_wget_curl
    fi
fi

# Default directories
DEFAULT_TARBALLS_DIR="$HOME/source_files/tarballs"
DEFAULT_SOURCES_DIR="$HOME/source_files/sources"

# Prompt for directories or use default
read -p "Use default directories for tarballs and sources? (Y/n): " use_default
if [[ "$use_default" =~ ^([nN][oO]|[nN])$ ]]; then
    read -p "Enter directory for downloaded tarballs: " TARBALLS_DIR
    read -p "Enter directory for extracted sources: " SOURCES_DIR
else
    TARBALLS_DIR=$DEFAULT_TARBALLS_DIR
    SOURCES_DIR=$DEFAULT_SOURCES_DIR
fi

# Create directories if they don't exist
mkdir -p "$TARBALLS_DIR"
mkdir -p "$SOURCES_DIR"

# Download URLs
URLS=(
    "https://ftp.gnu.org/gnu/automake/automake-1.17.tar.gz"
    "https://ftp.gnu.org/gnu/m4/m4-latest.tar.gz"
    "https://www.cpan.org/src/5.0/perl-5.40.0.tar.gz"
    "https://ftp.gnu.org/gnu/autoconf/autoconf-latest.tar.gz"
)

# Download and extract each file
for URL in "${URLS[@]}"; do
    FILENAME=$(basename "$URL")
    DEST_TARBALL="$TARBALLS_DIR/$FILENAME"

    # Download the file
    if command -v wget &> /dev/null; then
        wget -O "$DEST_TARBALL" "$URL"
    elif command -v curl &> /dev/null; then
        curl -o "$DEST_TARBALL" "$URL"
    else
        echo "Error: wget or curl should have been installed, but they are not found."
        exit 1
    fi

    # Extract the file
    tar -xzf "$DEST_TARBALL" -C "$SOURCES_DIR"
done

# Change ownership and permissions
sudo chown -R "$USER" "$TARBALLS_DIR" "$SOURCES_DIR"
sudo chmod -R u+rwx "$TARBALLS_DIR" "$SOURCES_DIR"

echo "All operations completed successfully!"

# Detect the current shell
CURRENT_SHELL=$(basename "$SHELL")

# Add the configuration to the appropriate shell config file
case "$CURRENT_SHELL" in
    bash)
        CONFIG_FILE="$HOME/.bashrc"
        ;;
    zsh)
        CONFIG_FILE="$HOME/.zshrc"
        ;;
    *)
        echo "Unsupported shell: $CURRENT_SHELL"
        exit 1
        ;;
esac

# Source the updated configuration
source "$CONFIG_FILE"

