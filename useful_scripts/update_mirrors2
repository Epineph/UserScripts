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
  Russia
  Ukraine
)

# Convert the array to a comma-separated list
countries_list=$(IFS=, ; echo "${countries[*]}")

# Run reflector to find the 20 fastest mirrors
sudo reflector --verbose \
  --age 12 \
  --latest 800 \
  --fastest 800 \
  --cache-timeout 1200 \
  --protocol https \
  --download-timeout 5 \
  --connection-timeout 5 \
  --sort rate \
  --threads 7 \
  --save /etc/pacman.d/mirrorlist
echo "Mirrorlist updated successfully!"
