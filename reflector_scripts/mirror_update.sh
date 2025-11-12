#!/bin/bash
# update_mirrors_optimized.sh
# ------------------------------------------------------------------------------
# This script updates the Pacman mirror list using reflector with an expanded
# pool of nearby countries and refined sorting based on rate (and an optional
# score threshold). HTTPS is enforced to ensure secure mirror downloads.
#
# Usage: sudo ./update_mirrors_optimized.sh
# ------------------------------------------------------------------------------

# Backup existing mirrorlist if backup doesn't already exist
if [ ! -f /etc/pacman.d/mirrorlist.backup ]; then
  sudo cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
fi

# Define an expanded list of nearby countries
countries=(
  Denmark
  Sweden
  Norway
  Finland
  Germany
  Netherlands
  Belgium
  Switzerland
  Austria
  France
  United_Kingdom
)

# Convert the array into a comma-separated string for --country flag
countries_list=$(IFS=, ; echo "${countries[*]}")

# ------------------------------
# Reflector parameters
# ------------------------------
max_age=12                # Maximum age (in hours) of the mirrors
latest=800                # Use the latest 800 mirrors in the pool
fastest=800               # From those, select the fastest 800
cache_timeout=1200        # Cache timeout in seconds (20 minutes)
download_timeout=5        # Timeout in seconds for mirror download
connection_timeout=5      # Timeout in seconds for connection attempts
threads=7                 # Number of threads to speed up the process
protocol="https"          # Enforce secure HTTPS protocol

# Optional: Uncomment to use a scoring threshold for mirror quality
score_threshold=300

# Execute reflector with defined parameters, sorting by rate
sudo reflector --verbose \
  --country "$countries_list" \
  --age $max_age \
  --latest $latest \
  --fastest $fastest \
  --cache-timeout $cache_timeout \
  --download-timeout $download_timeout \
  --connection-timeout $connection_timeout \
  --sort rate \
  --threads $threads \
  --protocol $protocol \
  --score $score_threshold \
  --save /etc/pacman.d/mirrorlist

echo "Mirrorlist updated successfully!"

