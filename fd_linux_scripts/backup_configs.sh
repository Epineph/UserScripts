#!/bin/bash
# backup_configs.sh - Find and backup configuration files

cat <<EOF
Usage: backup_configs.sh backup_directory

Description:
  This script finds configuration files (e.g., .conf, .cfg) and copies them to a backup directory.

Arguments:
  backup_directory  The directory to copy the configuration files to.

Examples:
  backup_configs.sh /path/to/backup
EOF

backup_dir="$1"

# Find configuration files and copy them to the backup directory
fd -e conf -e cfg --type file -0 | xargs -0 -I{} cp {} "$backup_dir"

