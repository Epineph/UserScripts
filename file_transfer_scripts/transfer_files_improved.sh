#!/bin/bash

# Define variables
REMOTE_USER="root"
REMOTE_HOST="192.168.1.72"
REMOTE_PATH="/usr/local/bin"

# Function to transfer files
transfer_files() {
    local local_path=$1
    echo "Starting file transfer from $local_path to $REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH"
    
    #  sync command to transfer files
    rsync -avz -e "ssh" "$local_path" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH"
    
    if [ $? -eq 0 ]; then
        echo "Files transferred successfully from $local_path!"
    else
        echo "File transfer failed from $local_path!"
    fi
}

# Main loop to collect directories
while true; do
    read -r -p "Enter the local directory path to transfer (or press Enter to finish): " LOCAL_PATH
    if [ -z "$LOCAL_PATH" ]; then
        break
    fi
    
    if [ -d "$LOCAL_PATH" ]; then
        transfer_files "$LOCAL_PATH"
    else
        echo "Directory $LOCAL_PATH does not exist. Please enter a valid directory."
    fi
done

echo "All file transfers are complete."

