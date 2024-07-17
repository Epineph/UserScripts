#!/bin/bash

# Define the directory to operate in
TARGET_DIR=$1
if [ -z "$TARGET_DIR" ]; then
    echo "Usage: $0 <target_directory>"
    exit 1
fi

# Create a backup file to store the original locations
BACKUP_FILE="$TARGET_DIR/.backup_locations.txt"
> "$BACKUP_FILE"

# Iterate over all directories in the target directory
for dir in "$TARGET_DIR"/*/; do
    [ -d "$dir" ] || continue  # Only directories

    # Iterate over all files in the directory
    for file in "$dir"*; do
        [ -f "$file" ] || continue  # Only files

        # Move the file to the target directory
        mv "$file" "$TARGET_DIR"
        echo "Moved $file to $TARGET_DIR"

        # Record the original location
        echo "$(basename "$file") $dir" >> "$BACKUP_FILE"
    done

    # Rename the directory to make it "invisible"
    mv "$dir" "$TARGET_DIR/.$(basename "$dir")"
    echo "Renamed $dir to $TARGET_DIR/.$(basename "$dir")"
done

echo "Files moved and directories renamed. Backup locations saved in $BACKUP_FILE."

