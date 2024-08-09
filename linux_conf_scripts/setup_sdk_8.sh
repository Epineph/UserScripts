#!/usr/bin/env bash

# Function to check for dotnet*.tar.gz and download if not found
function check_and_download_dotnet() {
    local search_pattern="$HOME/Downloads/dotnet*.tar.gz"
    local download_url="https://download.visualstudio.microsoft.com/download/pr/60218cc4-13eb-41d5-aa0b-5fd5a3fb03b8/6c42bee7c3651b1317b709a27a741362/dotnet-sdk-8.0.303-linux-x64.tar.gz"
    local download_destination="$HOME/Downloads/dotnet-sdk-8.0.303-linux-x64.tar.gz"

    # Check if a file matching the pattern exists
    for file in $search_pattern; do
        if [[ -f "$file" ]]; then
            DOTNET_FILE=$(realpath "$file")
            echo "File found: $DOTNET_FILE"
            return 0
        fi
    done

    # If no matching file was found, download it
    echo "File not found. Downloading..."
    curl -o "$download_destination" "$download_url"
    
    # Assign the downloaded file to DOTNET_FILE
    DOTNET_FILE=$(realpath "$download_destination")
    echo "Downloaded file: $DOTNET_FILE"
}

# Function to check if DOTNET_ROOT directory exists, create it if not, and extract the tar.gz file
function setup_dotnet() {
    if [[ ! -d "$DOTNET_ROOT" ]]; then
        echo "Creating $DOTNET_ROOT directory..."
        mkdir -p "$DOTNET_ROOT"
    else
        echo "$DOTNET_ROOT directory already exists."
    fi

    echo "Extracting $DOTNET_FILE to $DOTNET_ROOT..."
    tar zxf "$DOTNET_FILE" -C "$DOTNET_ROOT"
}

# Function to add and export DOTNET_ROOT to zsh_exports.zsh without duplication and prepend it to PATH
function update_zsh_profile() {
    local export_line="export DOTNET_ROOT=\$HOME/.dotnet"
    local zsh_file="$HOME/.zsh_profile/zsh_exports.zsh"

    # Check if DOTNET_ROOT is already in the file
    if ! grep -q "^$export_line" "$zsh_file"; then
        echo "Adding DOTNET_ROOT to $zsh_file..."
        sed -i "2i$export_line" "$zsh_file"
    else
        echo "DOTNET_ROOT already exported in $zsh_file."
    fi

    # Update PATH to prepend DOTNET_ROOT without duplication
    sed -i '/^export PATH=/ {
        /$DOTNET_ROOT/! s|^export PATH=|export PATH=$DOTNET_ROOT:|
    }' "$zsh_file"
}

# Main script execution
DOTNET_ROOT="$HOME/.dotnet"

# Step 1: Check for dotnet*.tar.gz or download it
check_and_download_dotnet

# Step 2: Setup .NET directory and extract the SDK
setup_dotnet

# Step 3: Update .zsh_profile/zsh_exports.zsh
update_zsh_profile

echo "Setup complete. Please source your zsh profile or restart your terminal."

