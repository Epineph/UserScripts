#!/bin/bash
# ==============================================================================
# Script: save_script.sh
# Description:
#   This script accepts one or several input file paths (scripts) and copies
#   each to /usr/local/bin without its original extension.
#
#   For example:
#       ~/path/to/my_script.sh  -->  /usr/local/bin/my_script
#
#   If a duplicate (target file already exists) is detected, the user is 
#   prompted to choose one of three options:
#       A: Overwrite all duplicates.
#       D: Decide for each conflict interactively.
#       K: Keep (skip) conflicting files.
#
#   This script uses a trick to re-run itself with sudo privileges if not
#   running as root. (It assumes that /usr/local/bin is writable by root.)
#
# Usage:
#   ./save_script.sh file1.sh file2.py file3.R ...
#
# Note:
#   It is not necessary to call sudo manually since the script
#   re-invokes itself when needed.
# ==============================================================================

# Re-run the script with sudo if not running as root.
#if [ "$(whoami)" != "root" ]; then
#    sudo su -s "$0" "$@"
#    exit
#fi


if [ "$(whoami)" != "root" ]
then
    sudo su -s "$0"
    exit
fi


# Check for at least one input file.
if [ "$#" -lt 1 ]; then
    echo "Usage: $0 file1 [file2 ...]"
    exit 1
fi

DEST_DIR="/usr/local/bin"
global_choice=""

# Loop through each input file.
for src_file in "$@"; do
    # Check if the source file exists.
    if [ ! -f "$src_file" ]; then
        echo "File '$src_file' does not exist. Skipping."
        continue
    fi

    # Get the base filename (e.g., "my_script.sh").
    filename=$(basename "$src_file")
    # Remove the extension (if any) so that "script.sh" becomes "script"
    dest_basename="${filename%.*}"
    dest_path="${DEST_DIR}/${dest_basename}"

    # Check if the destination file already exists.
    if [ -e "$dest_path" ]; then
        if [ "$global_choice" = "overwrite" ]; then
            echo "Overwriting existing file: $dest_path"
            cp "$src_file" "$dest_path"
        elif [ "$global_choice" = "keep" ]; then
            echo "Skipping (keeping existing): $dest_path"
        elif [ "$global_choice" = "decide" ]; then
            read -p "File '$dest_path' exists. Overwrite? (y/N): " ans
            if [[ "$ans" =~ ^[Yy]$ ]]; then
                cp "$src_file" "$dest_path"
                echo "Overwritten: $dest_path"
            else
                echo "Skipped: $dest_path"
            fi
        else
            # No global decision set; ask the user for how to handle duplicates.
            echo "Conflict: File '$dest_path' already exists."
            echo "Choose an option:"
            echo "  [A] Overwrite all duplicates"
            echo "  [D] Decide for each duplicate"
            echo "  [K] Keep all existing files (skip duplicates)"
            read -p "Enter A, D, or K: " choice
            case "$choice" in
                [Aa])
                    global_choice="overwrite"
                    cp "$src_file" "$dest_path"
                    echo "Overwritten: $dest_path"
                    ;;
                [Kk])
                    global_choice="keep"
                    echo "Skipping: $dest_path"
                    ;;
                [Dd])
                    global_choice="decide"
                    read -p "Overwrite '$dest_path'? (y/N): " ans
                    if [[ "$ans" =~ ^[Yy]$ ]]; then
                        cp "$src_file" "$dest_path"
                        echo "Overwritten: $dest_path"
                    else
                        echo "Skipped: $dest_path"
                    fi
                    ;;
                *)
                    echo "Invalid option. Skipping '$dest_path'."
                    ;;
            esac
        fi
    else
        # No conflict; copy the file.
        cp "$src_file" "$dest_path"
        echo "Copied '$src_file' to '$dest_path'"
    fi
done

