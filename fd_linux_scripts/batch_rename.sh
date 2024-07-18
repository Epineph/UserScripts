#!/bin/bash
# batch_rename.sh - Find and batch rename files

cat <<EOF
Usage: batch_rename.sh search_pattern rename_pattern

Description:
  This script finds files matching the search pattern and renames them according to the rename pattern.

Arguments:
  search_pattern   The pattern to search for files (supports wildcards).
  rename_pattern   The pattern to rename the files.

Examples:
  batch_rename.sh 'oldname*' 'newname*'
  batch_rename.sh '*.txt' 'document_*'
EOF

# Find files matching the search pattern
fd -e txt -e md "$1" | while read -r file; do
    # Generate the new name
    new_name=$(echo "$file" | sed "s/$1/$2/")
    # Rename the file
    mv "$file" "$new_name"
done

