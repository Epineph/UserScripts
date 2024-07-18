#!/bin/bash
# extract_targz.sh - Find and extract all tar.gz files

cat <<EOF
Usage: extract_targz.sh

Description:
  This script finds all .tar.gz files in the current directory and extracts them.

Examples:
  extract_targz.sh
EOF

# Find all .tar.gz files and extract them
fd -e tar.gz -0 | xargs -0 -I{} tar -xzvf {}

