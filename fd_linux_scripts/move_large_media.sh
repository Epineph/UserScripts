#!/bin/bash
# move_large_media.sh - Find and move large media files

cat <<EOF
Usage: move_large_media.sh destination_directory

Description:
  This script finds large media files (e.g., videos) larger than 500MB and moves them to the specified directory.

Arguments:
  destination_directory  The directory to move the large media files to.

Examples:
  move_large_media.sh /path/to/destination
EOF

destination="$1"

# Find large media files and move them
fd -e mp4 -e mkv -S +500M --type file -0 | xargs -0 -I{} mv {} "$destination"

