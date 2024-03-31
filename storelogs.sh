#!/bin/bash

# Source and target directories.
SOURCE_DIR="${LOG_PATH:-/logs}"
USER_TARGET_DIR="$HOME/.logs"
GLOBAL_LOG_DIR="/opt/UserLogs/$(whoami)" # Global log directory, specific to the user.

# Ensure the Loggers group exists, create if not.
if ! getent group Loggers >/dev/null; then
    sudo groupadd Loggers
fi

# Ensure the user is part of the Loggers group.
if ! id -nG "$(whoami)" | grep -qw "Loggers"; then
    sudo usermod -aG Loggers "$(whoami)"
fi

# Move logs to the user's home directory.
mkdir -p "$USER_TARGET_DIR"
cp -r "$SOURCE_DIR/"* "$USER_TARGET_DIR"
chmod -R 777 "$USER_TARGET_DIR"

# Copy logs to the global log directory.
sudo mkdir -p "$GLOBAL_LOG_DIR"
sudo cp -r "$SOURCE_DIR/"* "$GLOBAL_LOG_DIR"
sudo chown -R :Loggers "$GLOBAL_LOG_DIR"
sudo chmod -R 770 "$GLOBAL_LOG_DIR"

# Clean up the source directory.
rm -rf "$SOURCE_DIR/"*
