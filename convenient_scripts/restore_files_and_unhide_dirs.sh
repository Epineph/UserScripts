#!/bin/bash

# Define the directory to operate in
TARGET_DIR=$1
if [ -z "$TARGET_DIR" ]; then
    echo "Usage: $0 <target_directory>"
    exit 1
fi

# Backup file with original locations
BACKUP_FILE="$TARGET_DIR/.backup_locations.txt"
if [ ! -f "$BACKUP_FILE" ]; then
    echo "Backup file not found. Cannot restore."
    exit 1
fi

# Read the backup file and move the files back to their original locations
while read -r file dir; do
    mv "$TARGET_DIR/$file" "$dir"
    echo "Restored $file to $dir"
done < "$BACKUP_FILE"

# Rename the directories to make them visible again
for dir in "$TARGET_DIR"/.*; do
    [ -d "$dir" ] || continue  # Only directories

    # Rename the directory to make it visible
    mv "$dir" "$TARGET_DIR/$(basename "$dir" | sed 's/^\.//')"
    echo "Renamed $dir to $TARGET_DIR/$(basename "$dir" | sed 's/^\.//')"
done

# Remove the backup file
rm "$BACKUP_FILE"
echo "Files restored and directories renamed back. Backup file removed."

