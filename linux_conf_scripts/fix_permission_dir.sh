#!/bin/bash

# Set ownership to the current user
chown -R "$USER":"$USER" "$HOME/.gnupg"

# Set permissions for the .gnupg directory
chmod 700 "$HOME/.gnupg"

# Set permissions for all subdirectories
find "$HOME/.gnupg" -type d -exec chmod 700 {} \;

# Set permissions for all files
find "$HOME/.gnupg" -type f -exec chmod 600 {} \;

echo "Permissions and ownership for $HOME/.gnupg have been set correctly."

