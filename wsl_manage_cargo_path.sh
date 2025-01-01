###
#!/usr/bin/env bash

# Help Section
cat << EOF
SYNOPSIS
    Manages Rust cargo binaries across WSL and Windows environments by dynamically selecting the appropriate binary path.

DESCRIPTION
    This script ensures that Rust's cargo is correctly configured to work in both WSL and Windows environments.
    It dynamically sets the PATH to prioritize the appropriate cargo binary directory based on the environment
    (Windows or WSL). The script also supports adding cargo binaries to the current PATH for immediate use.

USAGE
    ./manage_cargo_path.sh [OPTIONS]

OPTIONS
    --use-wsl-bin          Use the WSL cargo binary directory (e.g., $HOME/.cargo/bin).
    --use-windows-bin      Use the Windows cargo binary directory (e.g., /mnt/c/Users/<username>/.cargo/bin).
    --add-to-path          Add the selected binary directory to the PATH temporarily.
    --help                 Display this help message.

EXAMPLES
    ./manage_cargo_path.sh --use-wsl-bin --add-to-path
        Prioritize WSL cargo binary directory and add it to the current PATH.

    ./manage_cargo_path.sh --use-windows-bin
        Prioritize Windows cargo binary directory but do not modify the PATH.
EOF

# Default values
CARGO_WSL_BIN="$HOME/.cargo/bin"
CARGO_WINDOWS_BIN="/mnt/c/Users/$(powershell.exe -Command "[System.Environment]::UserName" | tr -d '\r')/.cargo/bin"
USE_WSL_BIN=false
USE_WINDOWS_BIN=false
ADD_TO_PATH=false

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --use-wsl-bin)
            USE_WSL_BIN=true
            shift
            ;;
        --use-windows-bin)
            USE_WINDOWS_BIN=true
            shift
            ;;
        --add-to-path)
            ADD_TO_PATH=true
            shift
            ;;
        --help)
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Determine which cargo binary to use
if $USE_WSL_BIN && $USE_WINDOWS_BIN; then
    echo "Error: Cannot use both WSL and Windows cargo binaries simultaneously."
    exit 1
elif $USE_WSL_BIN; then
    SELECTED_BIN=$CARGO_WSL_BIN
elif $USE_WINDOWS_BIN; then
    SELECTED_BIN=$CARGO_WINDOWS_BIN
else
    echo "Error: No binary option specified. Use --use-wsl-bin or --use-windows-bin."
    exit 1
fi

# Add to PATH if requested
if $ADD_TO_PATH; then
    export PATH="$SELECTED_BIN:$PATH"
    echo "Added $SELECTED_BIN to PATH."
else
    echo "Selected binary path: $SELECTED_BIN"
fi

# Modify /etc/fstab to include swap file if not already present
SWAP_FILE_PATH="/swapfile"
if ! grep -q "$SWAP_FILE_PATH" /etc/fstab; then
    echo "Adding swap file entry to /etc/fstab..."
    echo "$SWAP_FILE_PATH none swap sw 0 0" | sudo tee -a /etc/fstab > /dev/null
    echo "Swap file entry added successfully."
else
    echo "Swap file entry already exists in /etc/fstab."
fi
