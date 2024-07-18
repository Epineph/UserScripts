#!/bin/bash
# sync_to_remote.sh - Find specific files and sync to a remote server

cat <<EOF
Usage: sync_to_remote.sh search_pattern remote_directory

Description:
  This script finds files of specific types and syncs them to a remote server using 'rsync'.

Arguments:
  search_pattern    The pattern to search for files (supports wildcards).
  remote_directory  The remote directory to sync the files to.

Examples:
  sync_to_remote.sh '*.jpg' user@remote:/path/to/destination
  sync_to_remote.sh 'file*' user@remote:/path/to/destination
EOF

search_pattern="$1"
remote_dir="$2"

# Find files matching the search pattern and sync them to the remote server
fd -e jpg -e png "$search_pattern" -0 | xargs -0 rsync -avz {} "$remote_dir"

