#!/bin/bash

# Function to display usage
usage() {
  echo "Usage: $0 -s <source_partition(s)> [-t <target_partition>] [-r <remote_ssh_target>]"
  echo "  -s : Source partition(s), separated by commas (e.g., /dev/sda1,/dev/sda2)"
  echo "  -t : (Optional) Target partition on local machine (e.g., /dev/sdb1)"
  echo "  -r : (Optional) SSH target in the format user@hostname:/target_partition"
  echo ""
  echo "Examples:"
  echo "  $0 -s /dev/sda1 -t /dev/sdb1"
  echo "  $0 -s /dev/sda1,/dev/sda2 -t /dev/sdb1"
  echo "  $0 -s /dev/sda1 -r user@remote:/dev/sdc1"
  exit 1
}

# Parse command-line arguments
while getopts "s:t:r:" opt; do
  case $opt in
    s) source_partitions=$OPTARG ;;
    t) target_partition=$OPTARG ;;
    r) remote_ssh_target=$OPTARG ;;
    *) usage ;;
  esac
done

# Check if the source partitions are provided
if [ -z "$source_partitions" ]; then
  usage
fi

# Check if neither target_partition nor remote_ssh_target is provided
if [ -z "$target_partition" ] && [ -z "$remote_ssh_target" ]; then
  echo "Error: Either a local target partition (-t) or a remote SSH target (-r) must be provided."
  usage
fi

# Split source partitions into an array
IFS=',' read -r -a source_array <<< "$source_partitions"

# Clone partitions
for src in "${source_array[@]}"; do
  if [ -n "$remote_ssh_target" ]; then
    # Cloning to a remote target over SSH
    ssh_user_host=$(echo $remote_ssh_target | cut -d':' -f1)
    ssh_target=$(echo $remote_ssh_target | cut -d':' -f2)
    
    echo "Cloning $src to $ssh_user_host:$ssh_target..."
    sudo ocs-onthefly -f "$src" -s "$ssh_user_host" -d "$ssh_target"
  elif [ -n "$target_partition" ]; then
    # Cloning to a local target
    echo "Cloning $src to $target_partition..."
    sudo ocs-onthefly -f "$src" -d "$target_partition"
  fi
done

echo "Cloning completed."

