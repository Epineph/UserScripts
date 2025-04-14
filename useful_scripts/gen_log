#!/bin/bash

# Directory where logs will be stored
LOG_DIR="$HOME/repos/generate_install_command"

# Ensure the directory exists
if [[ ! -d "$LOG_DIR" ]]; then
  echo "Error: Directory $LOG_DIR does not exist."
  exit 1
fi

# Check if a command is provided
if [[ $# -eq 0 ]]; then
  echo "Usage: $(basename $0) <command>"
  exit 1
fi

# Combine all provided arguments to form the command
user_command="$*"

# Find the highest output file number currently in the directory
latest_num=$(ls ${LOG_DIR}/output_*.txt 2>/dev/null | grep -oP 'output_\K\d+' | sort -n | tail -1)

# If no output files are found, start at 1, otherwise increment by 1
if [[ -z "$latest_num" ]]; then
  new_num=1
else
  new_num=$((latest_num + 1))
fi

# Name of the new output file
output_file="${LOG_DIR}/output_${new_num}.txt"

# Run the command interactively and log both stdout and stderr using `script`
echo "Running command: $user_command"
script -q -c "$user_command" "$output_file"

echo "Output has been logged to: $output_file"
