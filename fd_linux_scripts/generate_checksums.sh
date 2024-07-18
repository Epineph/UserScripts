#!/bin/bash
# generate_checksums.sh - Find files and generate checksums

cat <<EOF
Usage: generate_checksums.sh output_file

Description:
  This script finds files and generates checksums for them using 'sha256sum'.

Arguments:
  output_file  The file to save the checksums to.

Examples:
  generate_checksums.sh checksums.txt
EOF

output_file="$1"

# Find files and generate checksums
fd -e txt -e md -0 | xargs -0 sha256sum > "$output_file"

