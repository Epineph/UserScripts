#!/usr/bin/env bash
#
# makepkg_conf_optimizer.sh
#
# Author: OpenAI / ChatGPT
# Date: 2025-05-17
#
# DESCRIPTION:
#   Optimize makepkg.conf (system-wide or user-specific) to utilize all CPU cores for building packages
#   and set fastest possible compression methods for supported compressors.
#
# USAGE:
#   ./makepkg_conf_optimizer.sh [--user | --system] [--help]
#
# OPTIONS:
#   --user      Optimize ~/.makepkg.conf for the current user (default if run as non-root)
#   --system    Optimize /etc/makepkg.conf system-wide (requires root)
#   -h, --help  Show this help message and exit
#
# EXAMPLES:
#   sudo ./makepkg_conf_optimizer.sh --system
#   ./makepkg_conf_optimizer.sh --user
#
cat <<EOF
makepkg_conf_optimizer.sh - Arch Linux makepkg.conf optimizer

Optimizes makepkg.conf to use all CPU cores and the fastest supported compression algorithms.

USAGE:
  ./makepkg_conf_optimizer.sh [--user | --system] [--help]

See script comments for details.
EOF

set -euo pipefail

# FUNCTIONS

print_help() {
  sed -n 's/^# \{0,1\}//p' "$0" | grep -A20 'DESCRIPTION:' | grep -v '^#'
  exit 0
}

# Parse arguments
SCOPE="auto"  # auto: use --system if root, --user otherwise
for arg in "$@"; do
  case "$arg" in
    --user)   SCOPE="user";;
    --system) SCOPE="system";;
    -h|--help) print_help;;
    *) echo "Unknown option: $arg"; exit 1;;
  esac
done

# Detect if we are root
if [[ "$SCOPE" == "auto" ]]; then
  if [[ $EUID -eq 0 ]]; then
    SCOPE="system"
  else
    SCOPE="user"
  fi
fi

if [[ "$SCOPE" == "system" && $EUID -ne 0 ]]; then
  echo "ERROR: System-wide changes require root. Please run with sudo."
  exit 1
fi

# Detect number of CPU cores
NCORES=$(nproc)
echo "Detected CPU cores: $NCORES"

# Define target file
if [[ "$SCOPE" == "system" ]]; then
  MAKEPKG_CONF="/etc/makepkg.conf"
else
  MAKEPKG_CONF="$HOME/.makepkg.conf"
  # If user file does not exist, copy system one as a starting point
  if [[ ! -f "$MAKEPKG_CONF" ]]; then
    cp /etc/makepkg.conf "$MAKEPKG_CONF"
    echo "Copied /etc/makepkg.conf to $MAKEPKG_CONF"
  fi
fi

# Backup the original file
BACKUP="$MAKEPKG_CONF.bak.$(date +%s)"
cp "$MAKEPKG_CONF" "$BACKUP"
echo "Backup of original config saved as: $BACKUP"

# Function to safely set a key=value in makepkg.conf
set_makepkg_var() {
  local key="$1"
  local value="$2"
  local file="$3"
  if grep -q "^$key=" "$file"; then
    sed -i "s|^$key=.*|$key=$value|g" "$file"
  else
    echo "$key=$value" >> "$file"
  fi
}

# Set MAKEFLAGS to use all cores for compiling
set_makepkg_var "MAKEFLAGS" "\"-j$NCORES\"" "$MAKEPKG_CONF"
echo "Set MAKEFLAGS=\"-j$NCORES\""

# Set COMPRESSXZ, COMPRESSZST, and COMPRESSGZ to use all cores for compression
set_makepkg_var "COMPRESSXZ" "\"xz -c -T$NCORES -z -\"" "$MAKEPKG_CONF"
echo "Set COMPRESSXZ=\"xz -c -T$NCORES -z -\""

set_makepkg_var "COMPRESSZST" "\"zstd -c -T$NCORES -q -z -\"" "$MAKEPKG_CONF"
echo "Set COMPRESSZST=\"zstd -c -T$NCORES -q -z -\""

set_makepkg_var "COMPRESSGZ" "\"gzip -c -f -n -\"" "$MAKEPKG_CONF"
echo "Set COMPRESSGZ=\"gzip -c -f -n -\" (gzip uses multi-threading automatically on recent versions if available)"

set_makepkg_var "COMPRESSBZ2" "\"bzip2 -c -f -\"" "$MAKEPKG_CONF"
echo "Set COMPRESSBZ2=\"bzip2 -c -f -\""

set_makepkg_var "COMPRESSLZ" "\"lzip -c -f -\"" "$MAKEPKG_CONF"
echo "Set COMPRESSLZ=\"lzip -c -f -\""

set_makepkg_var "COMPRESSLZO" "\"lzop -c -f -\"" "$MAKEPKG_CONF"
echo "Set COMPRESSLZO=\"lzop -c -f -\""

set_makepkg_var "COMPRESSXZ" "\"xz -c -T$NCORES -z -\"" "$MAKEPKG_CONF"

set_makepkg_var "COMPRESSZST" "\"zstd -c -T$NCORES -q -z -\"" "$MAKEPKG_CONF"

# Enable ccache (if installed) for faster repeated builds
if command -v ccache &>/dev/null; then
  set_makepkg_var "BUILDENV" "\"!distcc color ccache check !sign\"" "$MAKEPKG_CONF"
  echo "Enabled ccache in BUILDENV (if installed)."
else
  echo "NOTE: ccache not installed. Install ccache for even faster builds of large packages."
fi

# Set PKGEXT and SRCEXT for faster (less compressed) package and source package formats
set_makepkg_var "PKGEXT" "'.pkg.tar.zst'" "$MAKEPKG_CONF"
set_makepkg_var "SRCEXT" "'.src.tar.gz'" "$MAKEPKG_CONF"
echo "Set PKGEXT and SRCEXT to fastest modern default formats."

echo "Optimization complete! Please review $MAKEPKG_CONF and test by building a package (e.g., with yay or makepkg)."

exit 0
