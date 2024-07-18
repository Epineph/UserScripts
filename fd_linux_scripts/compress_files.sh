#!/bin/bash
# compress_files.sh - Find specific files and compress them into a tar.gz archive

cat <<EOF
Usage: compress_files.sh search_pattern archive_name

Description:
  This script finds files matching the search pattern and compresses them into a single tar.gz archive.

Arguments:
  search_pattern   The pattern to search for files (supports wildcards).
  archive_name     The name of the tar.gz archive to create.

Examples:
  compress_files.sh '*.txt' my_archive
  compress_files.sh 'file*' backup
EOF

# Find files matching the search pattern and compress them
fd -e txt -e md "$1" -0 | xargs -0 tar -czvf "$2".tar.gz

