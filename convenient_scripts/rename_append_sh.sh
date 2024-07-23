#!/bin/bash
# batch_rename.sh - Find and batch rename files

cat <<EOF
Usage: batch_rename.sh 

Description:
  This script finds all files that do not have the .sh extension and renames them 
by appending .sh to their names.

Arguments:
  None

Examples:
  batch_rename.sh
EOF

# Find files that do not have the .sh extension
find . -type f ! -name '*.sh' | while read -r file; do
    # Generate the new name by appending .sh
    new_name="${file}.sh"
    # Rename the file
    mv "$file" "$new_name"
done
