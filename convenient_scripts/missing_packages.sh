#!/usr/bin/env bash
#
# install_missing_packages.sh
#
# This script installs optional dependencies that are not already installed using yay.
# A prompt is included before proceeding with the installation.

set -euo pipefail

# List of optional packages to install
PACKAGES=(
  python-cryptography
  python-hiredis
  python-pyopenssl
  python-tokenize-rt
  python-aiohttp
  python-xmltodict
  python-atomicwrites
  python-regex
  python-js2py
  python-pandas-datareader
  python-numexpr
  python-bottleneck
  python-numba
  python-xarray
  python-xlrd
  python-xlwt
  python-openpyxl
  python-xlsxwriter
  python-sqlalchemy
  python-psycopg2
  python-pymysql
  python-pytables
  python-blosc
  python-pyarrow
  python-fsspec
  python-snappy
  python-zstandard
)

# Check for missing packages
MISSING_PACKAGES=()
for PACKAGE in "${PACKAGES[@]}"; do
  if ! pacman -Qi "$PACKAGE" &>/dev/null; then
    MISSING_PACKAGES+=("$PACKAGE")
  fi
done

# Prompt and install missing packages
if [[ ${#MISSING_PACKAGES[@]} -eq 0 ]]; then
  echo "All specified optional packages are already installed."
else
  echo "The following optional packages are missing and will be installed:"
  echo "${MISSING_PACKAGES[*]}"
  read -rp "Do you want to proceed with the installation? [y/N] " RESPONSE
  RESPONSE=${RESPONSE,,} # Convert to lowercase
  if [[ "$RESPONSE" == "y" || "$RESPONSE" == "yes" ]]; then
    yay -S "${MISSING_PACKAGES[@]}"
  else
    echo "Installation canceled."
  fi
fi

