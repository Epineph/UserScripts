#!/bin/bash
# update_mirrors.sh
# ---------------------------------------------------------------------------
# This script updates the Pacman mirror list using reflector.
# It backs up the existing mirrorlist and generates a new one filtered by:
#   - Specified countries (to ensure regional relevance)
#   - Secure protocols (HTTPS)
#   - Mirror freshness and speed parameters
#
# Usage: sudo ./update_mirrors.sh
# ---------------------------------------------------------------------------

# Backup the existing mirrorlist if a backup doesn't already exist
if [ ! -f /etc/pacman.d/mirrorlist.backup ]; then
  sudo cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
fi

# Define the list of preferred countries
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
  "United Kingdom"
  Russia
  Ukraine
  Spain
  Portugal
  Poland
)

# Convert the array into a comma-separated list for the --country flag
countries_list=$(IFS=, ; echo "${countries[*]}")

# ------------------------------
# Parameters for reflector
# ------------------------------
max_age=12                # Maximum mirror age (in hours)
latest=800                # Consider the latest 800 mirrors
fastest=800               # From these, select the fastest 800 mirrors
cache_timeout=1200        # Cache mirror data for 1200 seconds (20 minutes)
download_timeout=5        # Timeout for downloads in seconds
connection_timeout=5      # Timeout for connections in seconds
threads=7                 # Number of threads to use for parallel processing
protocol="https"          # Use HTTPS exclusively for secure transfers

# Optional: Uncomment and adjust the following if you wish to filter by a minimum score
score_threshold=400

# Run reflector with the defined parameters
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
  --save /mnt/etc/pacman.d/mirrorlist

echo "Mirrorlist updated successfully!"

