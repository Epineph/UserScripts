#!/bin/bash

# Back up the existing mirrorlist if it doesn't exist
if [ ! -f /etc/pacman.d/mirrorlist.backup ]; then
  sudo cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
fi

# Define an expanded list of countries
countries=(
  Denmark
  Germany
  France
  Netherlands
  Sweden
  Norway
  Finland
  Austria
  Belgium
  Switzerland
  United_Kingdom
  Russia
  Ukraine
  Poland
  Czechia
  Estonia
  Latvia
  Lithuania
)

# Convert the array to a comma-separated list
countries_list=$(IFS=, ; echo "${countries[*]}")

# Use reflector to find a larger pool of mirrors and then sort them
sudo reflector --verbose \
  --age 12 \
  --n 2000 \
  --latest 1000 \
  --fastest 1000 \
  --sort rate \
  --score 400 \
  --threads 7 \
  --protocol https,http \
  --download-timeout 5 \
  --connection-timeout 5 \
  --save /etc/pacman.d/mirrorlist

echo "Mirrorlist updated successfully!"

