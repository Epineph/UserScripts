#!/bin/bash

# Extract group names from /etc/group
groups=$(cut -d: -f1 /etc/group | grep -v '^$')

# Use fzf to select groups (multi-select enabled)
selected_groups=$(echo "$groups" | fzf --multi --prompt="Select groups to add the user to: " --preview="grep -E \"^{}:\" /etc/group")

# Iterate over the selected groups and add the current user to each
for group in $selected_groups; do
  sudo usermod -aG "$group" "$USER"
done

echo "User $USER has been added to the selected groups."

