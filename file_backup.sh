#!/bin/bash

# Function to display help information
show_help() {
    cat << EOF
Usage: sudo $(basename "$0") [OPTIONS]... /path/to/file [backup_directory]
Create backups of a specified file, with options to place backups in a different directory or delete the original file.

Arguments:
  /path/to/file         Path to the file to be backed up.
  backup_directory      Directory where the backup should be created (optional).

Options:
  --help                Show this help message and exit.
  --delete-original     Delete the original file after creating the backup.

Examples:
  sudo $(basename "$0") /path/to/file
  sudo $(basename "$0") /path/to/file /path/to/backup_directory
  sudo $(basename "$0") --delete-original /path/to/file
EOF
}

# Function to create a backup of the file
create_backup() {
    local file_path=$1
    local backup_dir=$2
    local delete_original=$3

    # Ensure the file exists
    if [ ! -f "$file_path" ]; then
        echo "Error: File '$file_path' not found."
        exit 1
    fi

    # Get the directory and file name
    local file_dir=$(dirname "$file_path")
    local file_name=$(basename "$file_path")

    # Determine the backup directory
    if [ -z "$backup_dir" ]; then
        backup_dir=$file_dir
    fi

    # Ensure the backup directory exists
    mkdir -p "$backup_dir"

    # Determine the backup file name
    local backup_file="$backup_dir/$file_name.backup"
    local counter=1
    while [ -f "$backup_file" ]; do
        counter=$((counter + 1))
        backup_file="$backup_dir/${file_name}.backup_$counter"
    done

    # Create the backup
    cp "$file_path" "$backup_file"
    echo "Backup created: $backup_file"

    # Delete the original file if requested
    if [ "$delete_original" = true ]; then
        rm "$file_path"
        echo "Original file deleted: $file_path"
    fi
}

# Parse command-line options
delete_original=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --help)
            show_help
            exit 0
            ;;
        --delete-original)
            delete_original=true
            shift
            ;;
        *)
            break
            ;;
    esac
done

# Validate input
if [ $# -lt 1 ]; then
    show_help
    exit 1
fi

file_path=$1
backup_dir=$2

# Create the backup
create_backup "$file_path" "$backup_dir" "$delete_original"
