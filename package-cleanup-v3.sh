#!/bin/bash

# Enhanced Package Cleanup Script with Logging

PACKAGE_NAME=$1
LOG_PATH="/logs/package-removal"  # Base log path for package removal operations
DATE_DIR=$(date +%Y-%m-%d)  # Log directory by date
TIMESTAMP=$(date +%Y%m%d%H%M%S)  # Timestamp for individual operation logs

# Check for required argument
if [ -z "$PACKAGE_NAME" ]; then
    echo "Usage: $0 <package_name>"
    exit 1
fi

# Function to log command execution and its output
log_command() {
    local log_type=$1
    local command=$2

    local log_dir="$LOG_PATH/$log_type/$DATE_DIR"
    local log_file="$log_dir/$TIMESTAMP-$log_type.log"

    # Ensure the log directory exists
    if ! mkdir -p "$log_dir" 2>/dev/null; then
        echo "Warning: Could not create log directory '$log_dir'. Check permissions."
        return  # Skip logging if directory creation fails
    fi

    script -q -c "$command" -e "$log_file" || echo "Warning: Logging failed for command '$command'"
}


# Remove the specified package
echo "Removing package: $PACKAGE_NAME"
log_command "removal" "yay -Rns $PACKAGE_NAME"

# List and potentially remove orphaned packages
orphans=$(pacman -Qdtq)
if [ ! -z "$orphans" ]; then
    echo "Orphaned packages detected. Consider reviewing and removing them manually."
    echo "$orphans" > "$LOG_PATH/orphans/$DATE_DIR/$TIMESTAMP-orphans.log"
fi

# Function to handle orphaned packages (log and optionally remove)
handle_orphans() {
    local orphans_log="$LOG_PATH/orphans/$DATE_DIR/$TIMESTAMP-orphans.log"
    echo "Orphaned packages found: $(cat $orphans_log)"
    
    read -p "Do you want to remove these orphaned packages? [y/N] " answer
    if [[ $answer =~ ^[Yy]$ ]]; then
        log_command "orphans-removal" "sudo pacman -Rns $(cat $orphans_log)"
    fi
}

# Execute the orphan handling function
handle_orphans

# Optionally, invoke 'storelogs' to manage the new logs
# ./storelogs

echo "Package removal and cleanup operations completed. Check logs for details."

