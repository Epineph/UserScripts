#!/bin/bash
# delete_old_logs.sh - Find and delete old log files

cat <<EOF
Usage: delete_old_logs.sh duration

Description:
  This script finds log files older than the specified duration and deletes them.

Arguments:
  duration  The duration to find old log files (e.g., 30d, 1m, 2w).

Examples:
  delete_old_logs.sh 30d
  delete_old_logs.sh 1m
EOF

duration="$1"

# Find log files older than the specified duration and delete them
fd -e log --changed-before "$duration" --type file -0 | xargs -0 rm -v

