#!/bin/bash

check_and_install_packages() {
  local missing_packages=()

  # Check which packages are not installed
  for package in "$@"; do
    if ! pacman -Qi "$package" &> /dev/null; then
      missing_packages+=("$package")
    else
      echo "Package '$package' is already installed."
    fi
  done

  # If there are missing packages, ask the user if they want to install them
  if [ ${#missing_packages[@]} -ne 0 ]; then
    echo "The following packages are not installed: ${missing_packages[*]}"
    read -p "Do you want to install them? (Y/n) " -n 1 -r
    echo    # Move to a new line
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
      for package in "${missing_packages[@]}"; do
        yes | sudo pacman -S "$package"
        if [ $? -ne 0 ]; then
          echo "Failed to install $package. Aborting."
          exit 1
        fi
      done
    else
      echo "The following packages are required to continue:\
      ${missing_packages[*]}. Aborting."
      exit 1
    fi
  fi
}


echo "Before running this script to compile openssl from course, it is recommended updating the system and installing dependencies"

read -p "Do you want to update system and install dependencies before proceeding? (yes/no) " confirmation

if [ "$confirmation" == "yes" ]; then
    sudo pacman -Syu --needed --noconfirm
else
    echo "Skipping updating system and dependencies."
fi


pacman_packages=("wget" "base-devel" "python-pip" "python-requests" "python-beautifulsoup4" "ncurse" "git" "python-virtualenvwrapper")

for pkg in "${pacman_packages[@]}"; do
    check_and_install_packages "${pkg}"
done




# Step 2: Download the latest OpenSSL source code
echo "Downloading the latest OpenSSL source code..."


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

DOWNLOAD_LOCATION="$HOME/Downloads"
echo "The OpenSSL source code will be downloaded"
read -r -p "Do you want to download the openssl source code version, $LATEST_OPENSSL_VERSION, to your $HOME/Downloads folder (yes/no): " download_directory

if [ "$download_directory" == "yes" ]; then


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
