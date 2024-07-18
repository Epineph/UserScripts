#!/bin/bash
# search_replace.sh - Search and replace text in files

cat <<EOF
Usage: search_replace.sh search_pattern replace_pattern

Description:
  This script searches for a pattern in files and replaces it with another pattern.

Arguments:
  search_pattern   The pattern to search for in files.
  replace_pattern  The pattern to replace the search pattern with.

Examples:
  search_replace.sh 'foo' 'bar'
  search_replace.sh 'oldtext' 'newtext'
EOF

# Find files containing the search pattern
fd -e txt -e md -0 -x grep -IlZ "$1" | xargs -0 -r sed -i "s/$1/$2/g"

