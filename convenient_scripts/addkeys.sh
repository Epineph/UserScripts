#!/bin/bash

# Function to show help message
show_help() {
  cat <<EOF
Usage: $0 key1 [key2 ... keyN]

This script adds and signs one or more pacman keys.

Arguments:
  key1, key2, ... keyN    Keys to be added and signed.

Example:
  $0 72BF227DD76AE5BF 63CC496475267693 12345678
EOF
}

# Check if at least one key is provided or if help is requested
if [ "$#" -lt 1 ] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
  show_help
  exit 1
fi

# Iterate over all provided keys
for key in "$@"; do
  echo "Adding and signing key: $key"
  sudo pacman-key -r "$key" && sudo pacman-key --lsign-key "$key"
done

echo "All keys processed."

