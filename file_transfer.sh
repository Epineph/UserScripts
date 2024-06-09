#!/bin/bash

# Function to display usage instructions
usage() {
    cat << EOF
Usage: $0 [-l | --local | --local-transfer] [-r | --recursive] [-s|--ssh username@ip] /path/to/source /path/to/destination

Options:
  -l, --local, --local-transfer   Perform a local file transfer
  -r, --recursive                 Recursively transfer directories
  -s, --ssh username@ip           Perform a file transfer over SSH

Examples:
  Local transfer, non-recursive:
    $0 -l /path/to/source /path/to/destination

  Local transfer, recursive:
    $0 -l -r /path/to/source /path/to/destination

  SSH transfer, non-recursive:
    $0 -s user@host:/path/to/source /path/to/destination

  SSH transfer, recursive:
    $0 -r -s user@host:/path/to/source /path/to/destination
EOF
    exit 1
}

# Parsing command-line arguments
PARSED_OPTIONS=$(getopt -o lrs: --long local,local-transfer,recursive,ssh: -- "$@")
if [ $? -ne 0 ]; then
    usage
fi

eval set -- "$PARSED_OPTIONS"

LOCAL_TRANSFER=0
RECURSIVE=0
SSH_TRANSFER=0
SSH_USER_HOST=""
SOURCE=""
DESTINATION=""

# Extract options and their arguments into variables
while true; do
    case "$1" in
        -l|--local|--local-transfer)
            LOCAL_TRANSFER=1
            shift
            ;;
        -r|--recursive)
            RECURSIVE=1
            shift
            ;;
        -s|--ssh)
            SSH_TRANSFER=1
            SSH_USER_HOST="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            usage
            ;;
    esac
done

# Remaining arguments should be source and destination paths
if [ $# -ne 2 ]; then
    usage
fi

SOURCE="$1"
DESTINATION="$2"

# Building the rsync command
RSYNC_CMD="rsync -avh"

if [ $RECURSIVE -eq 1 ]; then
    RSYNC_CMD="$RSYNC_CMD --recursive"
fi

if [ $SSH_TRANSFER -eq 1 ]; then
    if [[ $SOURCE == /* ]]; then
        RSYNC_CMD="$RSYNC_CMD -e ssh $SOURCE $SSH_USER_HOST:$DESTINATION"
    else
        RSYNC_CMD="$RSYNC_CMD -e ssh $SSH_USER_HOST:$SOURCE $DESTINATION"
    fi
else
    RSYNC_CMD="$RSYNC_CMD $SOURCE $DESTINATION"
fi

# Execute the rsync command
echo "Executing: $RSYNC_CMD"
$RSYNC_CMD

# Check if rsync succeeded
if [ $? -eq 0 ]; then
    echo "Transfer completed successfully."
else
    echo "Transfer failed."
fi
