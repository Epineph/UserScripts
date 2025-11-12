#!/bin/bash

# Function to display usage
usage() {
    echo "Usage: $0 [-d | --directory <directory>] <file1> <file2> ... <fileN>"
    exit 1
}

# Parse arguments
DIRECTORY=""
FILES=()

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -d|--directory)
            DIRECTORY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            FILES+=("$1")
            shift
            ;;
    esac
done

# Check if files were provided
if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "Error: No files specified."
    usage
fi

# If no directory is provided, ask the user
if [[ -z "$DIRECTORY" ]]; then
    read -p "No directory specified. Do you want to use the current directory? (y/n) " response
    if [[ "$response" != "y" ]]; then
        echo "Backup aborted."
        exit 1
    fi
    DIRECTORY=$(pwd)
fi

# Create the backup directory if it does not exist
BACKUP_DIR="$DIRECTORY/backup"
mkdir -p "$BACKUP_DIR"

# Move the files to the backup directory
for FILE in "${FILES[@]}"; do
    if [[ -e "$FILE" ]]; then
        mv "$FILE" "$BACKUP_DIR"
        echo "Moved $FILE to $BACKUP_DIR"
    else
        echo "Warning: $FILE does not exist."
    fi
done

echo "Backup completed."

