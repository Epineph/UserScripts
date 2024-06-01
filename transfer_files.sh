#!/bin/bash

# Define variables
REMOTE_USER="heini"
REMOTE_HOST="192.168.1.74"
REMOTE_PATH="/home/heini/Documents"
LOCAL_PATH="/home/heini/personalScripts"

# Function to transfer files
transfer_files() {
    echo "Starting file transfer from $LOCAL_PATH to $REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH"
    
    # Rsync command to transfer files
    rsync -avz -e "ssh" "$LOCAL_PATH" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH"
    
    if [ $? -eq 0 ];    then
        echo "Files transferred successfully!"
    else
        echo "File transfer failed!"
    fi
}

# Run the transfer function
transfer_files

