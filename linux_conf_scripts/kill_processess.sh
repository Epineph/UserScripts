#!/bin/bash

# Check for necessary packages
for pkg in htop fzf; do
    if ! command -v $pkg &> /dev/null; then
        echo "$pkg could not be found"
        echo "Install it? (y/n)"
        read -r response
        if [[ "$response" == "y" ]]; then
            sudo pacman -Syu $pkg
        else
            echo "Script cannot continue without $pkg. Exiting."
            exit 1
        fi
    fi
done

# Get a list of processes sorted by CPU usage
processes=$(ps aux --sort=-%cpu | awk '{print $2, $3, $4, $11}' | fzf -m)

# If no process is selected, exit
if [[ -z "$processes" ]]; then
    echo "No process selected. Exiting."
    exit 0
fi

# Split the selected processes into an array
IFS=$'\n' read -rd '' -a process_array <<<"$processes"

# Loop through the array and kill each process
for process in "${process_array[@]}"; do
    pid=$(echo "$process" | awk '{print $1}')
    echo "Killing process $pid"
    kill -9 "$pid"
done

echo "Done."





In this script, the `-m` option is added to the `fzf` command to enable multi-select. The selected processes are then split into an array, and each process is killed in a loop.
