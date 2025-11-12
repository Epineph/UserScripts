#!/bin/bash

# Default backup directory
BACKUP_DIR="$HOME/key_backups"
ENCRYPTED_BACKUP="$BACKUP_DIR/backup.tar.gz.gpg"

# Function to display usage
show_help() {
    cat << EOF
Usage: ./restore_keys.sh [OPTIONS]

This script restores GPG and SSH keys from an encrypted backup tarball.

Options:
  --backup-path <PATH>  Specify the path to the encrypted backup file (default: $ENCRYPTED_BACKUP).
  --help                Show this help message.

Steps performed:
1. Decrypts the backup tarball to a temporary directory.
2. Restores GPG keys and configures them for Git.
3. Restores SSH keys to ~/.ssh and configures them for authentication.
4. Cleans up temporary files after successful restoration.

Examples:
  Restore keys from the default backup location:
    ./restore_keys.sh

  Restore keys from a custom backup location:
    ./restore_keys.sh --backup-path /path/to/backup.tar.gz.gpg

EOF
}

# Function to decrypt the backup tarball
decrypt_backup() {
    echo "Decrypting backup..."
    mkdir -p "$BACKUP_DIR/restored"
    gpg --decrypt "$ENCRYPTED_BACKUP" > "$BACKUP_DIR/restored/backup.tar.gz"
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to decrypt the backup."
        exit 1
    fi

    echo "Extracting files from decrypted tarball..."
    tar -xzf "$BACKUP_DIR/restored/backup.tar.gz" -C "$BACKUP_DIR/restored/"
    rm "$BACKUP_DIR/restored/backup.tar.gz"
    echo "Decrypted and extracted files to $BACKUP_DIR/restored."
}

# Function to restore GPG keys
restore_gpg_keys() {
    echo "Restoring GPG keys..."
    local gpg_dir="$BACKUP_DIR/restored/gpg"

    if [[ -f "$gpg_dir/public_key.asc" ]]; then
        gpg --import "$gpg_dir/public_key.asc"
        echo "Imported GPG public key."
    fi

    if [[ -f "$gpg_dir/private_key.asc" ]]; then
        gpg --import "$gpg_dir/private_key.asc"
        echo "Imported GPG private key."
    fi

    echo "Listing restored GPG keys:"
    gpg --list-keys
    gpg --list-secret-keys
}

# Function to restore SSH keys
restore_ssh_keys() {
    echo "Restoring SSH keys..."
    local ssh_dir="$BACKUP_DIR/restored/ssh"
    local ssh_key_dir="$HOME/.ssh"

    mkdir -p "$ssh_key_dir"

    if [[ -f "$ssh_dir/private_key" ]]; then
        mv "$ssh_dir/private_key" "$ssh_key_dir/id_rsa"
        chmod 600 "$ssh_key_dir/id_rsa"
        echo "Restored private SSH key to $ssh_key_dir/id_rsa."
    fi

    if [[ -f "$ssh_dir/public_key" ]]; then
        mv "$ssh_dir/public_key" "$ssh_key_dir/id_rsa.pub"
        chmod 644 "$ssh_key_dir/id_rsa.pub"
        echo "Restored public SSH key to $ssh_key_dir/id_rsa.pub."
    fi

    echo "Starting SSH agent..."
    eval "$(ssh-agent -s)"
    ssh-add "$ssh_key_dir/id_rsa"
    echo "Private SSH key added to SSH agent."

    echo "Testing SSH authentication with GitHub..."
    ssh -T git@github.com || echo "SSH authentication failed. Ensure your public key is added to GitHub."
}

# Function to clean up temporary files
cleanup() {
    echo "Cleaning up temporary files..."
    rm -rf "$BACKUP_DIR/restored"
    echo "Temporary files cleaned up."
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
    --backup-path)
        ENCRYPTED_BACKUP="$2"
        shift
        ;;
    --help)
        show_help
        exit 0
        ;;
    *)
        echo "Unknown option: $1"
        show_help
        exit 1
        ;;
    esac
    shift
done

# Validate input
if [[ ! -f "$ENCRYPTED_BACKUP" ]]; then
    echo "Error: Encrypted backup file not found at $ENCRYPTED_BACKUP."
    exit 1
fi

# Execute restoration steps
decrypt_backup
restore_gpg_keys
restore_ssh_keys
cleanup

echo "Key restoration completed successfully!"

