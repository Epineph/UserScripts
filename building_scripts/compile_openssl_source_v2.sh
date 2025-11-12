#!/bin/bash

# This script compiles and installs OpenSSL from source on Arch Linux
# It can automatically fetch the latest OpenSSL version if not specified.

# Step 1: Update system and install necessary dependencies
echo "Updating system and installing dependencies..."
sudo pacman -Syu --needed --noconfirm
sudo pacman -S --needed --noconfirm base-devel wget python-pip



# Step 2: Install BeautifulSoup4 and requests (for Python version fetching)
pip install beautifulsoup4 requests

# Step 3: Python script to fetch the latest OpenSSL version
fetch_latest_openssl_version=$(cat << 'EOF'
import requests
from bs4 import BeautifulSoup

def get_latest_openssl_version():
    url = "https://www.openssl.org/source/"
    response = requests.get(url)
    soup = BeautifulSoup(response.text, 'html.parser')
    versions = []
    for link in soup.find_all('a'):
        href = link.get('href')
        if href and 'openssl-' in href and href.endswith('.tar.gz'):
            version = href.split('-')[1].split('.tar.gz')[0]
            versions.append(version)
    versions = sorted(versions, reverse=True)
    for version in versions:
        if version[0].isdigit():  # Ensure it's a stable version
            return version
    return None

latest_version = get_latest_openssl_version()
if latest_version:
    print(latest_version)
else:
    print("Error fetching the latest version.")
EOF
)

# Fetch the latest version using Python
LATEST_OPENSSL_VERSION=$(python -c "$fetch_latest_openssl_version")

# Step 4: Prompt the user to select OpenSSL version
echo "The latest stable version of OpenSSL is: $LATEST_OPENSSL_VERSION"
read -p "Do you want to install the latest version? (yes/no) " use_latest
if [ "$use_latest" == "yes" ]; then
    OPENSSL_VERSION=$LATEST_OPENSSL_VERSION
else
    read -p "Please enter the OpenSSL version you wish to install: " OPENSSL_VERSION
fi

# Step 5: Download the specified OpenSSL source code
echo "Downloading OpenSSL version $OPENSSL_VERSION..."
wget https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz

# Step 6: Extract the downloaded tarball
echo "Extracting OpenSSL source..."
tar -xzf openssl-$OPENSSL_VERSION.tar.gz
cd openssl-$OPENSSL_VERSION

# Step 7: Configure the build options
echo "Configuring OpenSSL..."
./config --prefix=/usr/local/openssl --openssldir=/usr/local/openssl shared zlib

# Step 8: Compile OpenSSL
echo "Compiling OpenSSL..."
make -j$(nproc)

# Step 9: Test the build (Optional, but recommended)
echo "Running tests..."
make test

# Step 10: Install OpenSSL
echo "Installing OpenSSL..."
sudo make install

# Step 11: Update the shared libraries cache
echo "Updating shared libraries cache..."
sudo ldconfig

# Step 12: Update system paths to use the new OpenSSL
echo "Updating system paths..."
echo 'export PATH="/usr/local/openssl/bin:$PATH"' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH="/usr/local/openssl/lib:$LD_LIBRARY_PATH"' >> ~/.bashrc
echo 'export PKG_CONFIG_PATH="/usr/local/openssl/lib/pkgconfig:$PKG_CONFIG_PATH"' >> ~/.bashrc
source ~/.bashrc

# Step 13: Verify the installation
echo "Verifying the installation..."
openssl version -a

echo "OpenSSL installation complete!"

