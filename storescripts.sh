#!/bin/bash

# Paths where scripts will be placed.
logcmd_path="/usr/local/bin/logcmd"
changePermissions_path="/usr/local/bin/changePermissions"
storelogs_path="/usr/local/bin/storelogs"
buildFromSource_path="/usr/local/bin/buildFromSource"


# Check if the scripts already exist.
if [[ ! -f "$logcmd_path" ]] || [[ ! -f "$storelogs_path" ]]; then
    echo "Scripts not found. Setting up..."

    # Temporary clone directory.
    temp_clone_dir="$(mktemp -d)"
    
    # Clone the repository.
    git clone https://github.com/Epineph/output_logging "$temp_clone_dir"
    
    # Move the scripts to the correct locations and make them executable.
    sudo mv "$temp_clone_dir/logcmd.sh" "$logcmd_path"
    sudo mv "$temp_clone_dir/storelogs.sh" "$storelogs_path"
    sudo mv "$temp_clone_dir/changePermissions.sh" "$changePermissions_path"
    sudo mv "$temp_clone_dir/buildFromSource.sh" "$buildFromSource_path"
    sudo chmod +x "$logcmd_path"
    sudo chmod +x "$storelogs_path"
    sudo chmod +x "$changePermissions_path"
    sudo chmod +x "$buildFromSource_path"
    
    # Clean up the temporary clone directory.
    rm -rf "$temp_clone_dir"
else
    echo "Scripts already set up."
fi

# Set up the initial directories with correct permissions.
sudo mkdir -p /logs
sudo chmod 777 /logs
sudo mkdir -p /opt/UserLogs
sudo chmod 777 /opt/UserLogs # Note: adjust permissions as needed for your security requirements

# Ensure the Loggers group exists.
if ! getent group Loggers >/dev/null; then
    sudo groupadd Loggers
fi

echo "Setup complete."
