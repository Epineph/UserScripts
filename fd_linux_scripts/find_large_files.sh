#!/bin/bash
# find_large_files.sh - Find and summarize large files

cat <<EOF
Usage: find_large_files.sh

Description:
  This script finds files larger than 100MB, displays their sizes, and summarizes the total size.

Examples:
  find_large_files.sh
EOF

# Find files larger than 100MB and display their sizes
fd -S +100M --type file --exec ls -lh {} \; | awk '{print $9 ": " $5}'

# Calculate total size of these files
total_size=$(fd -S +100M --type file --exec du -ch {} + | grep total$)
echo "Total size: $total_size"

