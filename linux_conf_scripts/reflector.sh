#!/bin/bash

if [ ! -f /etc/pacman.d/mirrorlist.backup ]; then
  sudo cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
fi


# Define the list of countries
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
  United Kingdom
)

# Convert the array to a comma-separated list
countries_list=$(IFS=, ; echo "${countries[*]}")

# Run reflector to find the 20 fastest mirrors
sudo reflector --verbose \
  --country $countries_list \
  --age 12 \
  --latest 150 \
  --fastest 150 \
  --cache-timeout 1800 \
  --download-timeout 10 \
  --connection-timeout 10 \
  --sort rate \
  --threads 3 \
  --save /etc/pacman.d/mirrorlist

echo "Mirrorlist updated successfully!"
