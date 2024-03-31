#!/bin/bash

# Use the LOG_PATH environment variable if set; default to /logs if not.
LOG_PATH="${LOG_PATH:-/logs}"
COMBINED_PATH="$LOG_PATH/combined"

# Create necessary directories.
mkdir -p "$COMBINED_PATH"
DATE_DIR=$(date +%Y-%m-%d)
mkdir -p "$COMBINED_PATH/$DATE_DIR"

# Define log filename based on the current timestamp.
TIMESTAMP=$(date +%Y%m%d%H%M%S)
COMBINED_FILE="$COMBINED_PATH/$DATE_DIR/$TIMESTAMP.log"

# Execute the command and log outputs using 'script' to maintain interactivity.
script -q -c "$*" -e "$COMBINED_FILE"


