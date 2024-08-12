#!/bin/bash

# Define the custom directory
custom_dir="$HOME/logs"

# Define the zsh exports file
zsh_exports="$HOME/.zsh_profile/zsh_exports.zsh"

# Function to check if the custom directory exists, if not create it
create_custom_dir() {
  if [ ! -d "$custom_dir" ]; then
    echo "Creating custom directory at $custom_dir"
    mkdir -p "$custom_dir"
  else
    echo "Custom directory already exists at $custom_dir"
  fi
}

# Function to check if the custom directory is already in the PATH
check_and_prepend_to_path() {
  if [[ ":$PATH:" != *":$custom_dir:"* ]]; then
    echo "Prepending $custom_dir to PATH"
    export PATH="$custom_dir:$PATH"
    
    # Find the first non-comment line in the zsh exports file
    first_non_comment_line=$(grep -n '^[^#]' "$zsh_exports" | cut -d : -f 1 | head -n 1)
    
    # Insert the new PATH export line just after the initial comments
    if [ -z "$first_non_comment_line" ]; then
      echo "export PATH=$custom_dir:\$PATH" >> "$zsh_exports"
    else
      sed -i "${first_non_comment_line}i export PATH=$custom_dir:\$PATH" "$zsh_exports"
    fi
  else
    echo "$custom_dir is already in PATH"
  fi
}

# Execute the functions
create_custom_dir
check_and_prepend_to_path

echo "Custom directory setup completed."

