#!/bin/bash

# Function to check which shell is running
check_shell() {
  echo "$SHELL"
}

# Function to get clipboard contents using xclip
get_clipboard_contents() {
  xclip -selection clipboard -o
}

# Function to get the current shell session details
get_session_details() {
  ps -p $$
}

# Function to create log directory and file
create_log_file() {
  log_dir="$HOME/.log/$(date +%Y-%m-%d)"
  
  # Check if directory exists, if not create it
  if [ ! -d "$log_dir" ]; then
    mkdir -p "$log_dir"
  fi

  # Check if the user owns the directory and if the permissions are correct
  owner=$(stat -c '%U' "$log_dir")
  perms=$(stat -c '%a' "$log_dir")
  
  if [ "$owner" != "$USER" ] || [ "$perms" != "700" ]; then
    echo "Fixing ownership and permissions of $log_dir"
    sudo chown "$USER":"$USER" "$log_dir"
    sudo chmod 700 "$log_dir"
  fi
  
  # Create the log file with incremented name
  log_file="$log_dir/log_$(($(ls "$log_dir" | wc -l) + 1)).txt"
  echo "$log_file"
}

# Parsing arguments
case "$1" in
  -c|--clipboard)
    content=$(get_clipboard_contents)
    ;;
  -s|--session)
    content=$(get_session_details)
    ;;
  *)
    echo "Usage: $0 {-c|--clipboard|-s|--session}"
    exit 1
    ;;
esac

# Write content to the log file
log_file=$(create_log_file)
echo "$content" > "$log_file"
echo "Log written to $log_file"

