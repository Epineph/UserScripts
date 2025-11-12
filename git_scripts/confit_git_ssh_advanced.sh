#!/bin/bash

# Default backup location
DEFAULT_BACKUP_DIR="$HOME/key_backups"

# Display help section
show_help() {
    cat << EOF
Usage: ./config_git_ssh_backup.sh [OPTIONS]

This script configures Git with GPG signing and SSH keys, and backs up the keys securely.

Options:
  --backup-dir <PATH>   Specify a custom backup directory (default: $DEFAULT_BACKUP_DIR).
  --usb-path <PATH>     Specify a USB drive path for additional backup.
  --encrypt             Encrypt the backup files with a passphrase.
  --help                Show this help message.

Steps performed:
1. Generates GPG and SSH keys if they don't exist.
2. Configures Git to use the generated GPG key.
3. Backs up GPG and SSH keys to the specified directory or USB.
4. Encrypts backups if --encrypt is provided.

EOF
}

# Function to generate a GPG key
generate_gpg_key() {
    echo "Generating a new GPG key..."
    gpg --full-generate-key

    echo "Listing your GPG keys..."
    gpg --list-secret-keys --keyid-format=long

    echo "Enter the GPG key ID (long form) you'd like to use for signing commits:"
    read -r GPG_KEY_ID
    if [[ -z "$GPG_KEY_ID" ]]; then
        echo "Error: GPG key ID is required."
        exit 1
    fi

    git config --global user.signingkey "$GPG_KEY_ID"

    echo "Would you like to sign all commits by default? (y/n)"
    read -r SIGN_ALL_COMMITS

    if [[ "$SIGN_ALL_COMMITS" == "y" ]]; then
        git config --global commit.gpgsign true
    fi

    echo "GPG key generated and Git configured to use it for signing commits."
    echo "Here is your GPG public key in GitHub-compatible format:"
    gpg --armor --export "$GPG_KEY_ID"

    # Save GPG keys for backup
    mkdir -p "$BACKUP_DIR/gpg"
    gpg --armor --export "$GPG_KEY_ID" > "$BACKUP_DIR/gpg/public_key.asc"
    gpg --armor --export-secret-keys "$GPG_KEY_ID" > "$BACKUP_DIR/gpg/private_key.asc"
    echo "GPG keys saved to $BACKUP_DIR/gpg/"
}

# Function to generate an SSH key
generate_ssh_key() {
    echo "Generating a new SSH key..."
    SSH_KEY="$HOME/.ssh/id_rsa"

    if [[ -f "$SSH_KEY" ]]; then
        echo "SSH key exists. Generate a new one and backup the old? (y/n): "
        read -r yn
        if [[ "$yn" == "y" ]]; then
            BACKUP_DIR="$HOME/.ssh_backup"
            mkdir -p "$BACKUP_DIR"
            rsync -av --progress "$HOME/.ssh/" "$BACKUP_DIR/" && rm -f "$SSH_KEY"*
            echo "Old SSH key backed up to $BACKUP_DIR."
        else
            echo "Skipping SSH key generation."
            return
        fi
    fi

    echo "Enter your email address for the SSH key:"
    read -r SSH_EMAIL
    if [[ -z "$SSH_EMAIL" ]]; then
        echo "Error: Email address is required for SSH key generation."
        exit 1
    fi

    ssh-keygen -t rsa -b 4096 -C "$SSH_EMAIL" -f "$SSH_KEY"

    echo "Starting the SSH agent..."
    eval "$(ssh-agent -s)"

    echo "Adding the SSH private key to the SSH agent..."
    ssh-add "$SSH_KEY"

    # Save SSH keys for backup
    mkdir -p "$BACKUP_DIR/ssh"
    cp "${SSH_KEY}" "$BACKUP_DIR/ssh/private_key"
    cp "${SSH_KEY}.pub" "$BACKUP_DIR/ssh/public_key"
    echo "SSH keys saved to $BACKUP_DIR/ssh/"

    echo "Here is your SSH public key:"
    cat "${SSH_KEY}.pub"

    echo "To add the SSH key to GitHub, follow these steps:"
    echo "1. Copy the SSH key above."
    echo "2. Go to GitHub and navigate to Settings > SSH and GPG keys > New SSH key."
    echo "3. Paste the SSH key and give it a title."
}

# Function to encrypt backups
encrypt_backups() {
    echo "Encrypting backups with a passphrase..."
    tar -czf "$BACKUP_DIR/backup.tar.gz" -C "$BACKUP_DIR" .
    gpg --symmetric --cipher-algo AES256 "$BACKUP_DIR/backup.tar.gz"
    rm "$BACKUP_DIR/backup.tar.gz"
    echo "Encrypted backup created at $BACKUP_DIR/backup.tar.gz.gpg"
}

# Function to copy backups to USB
backup_to_usb() {
    USB_PATH="$1"
    if [[ -z "$USB_PATH" || ! -d "$USB_PATH" ]]; then
        echo "Error: USB path is invalid or not specified."
        exit 1
    fi

    echo "Copying backups to USB ($USB_PATH)..."
    rsync -av --progress "$BACKUP_DIR/" "$USB_PATH/key_backups/"
    echo "Backups copied to USB."
}

# Main function
main() {
    BACKUP_DIR="$DEFAULT_BACKUP_DIR"
    ENCRYPT=false
    USB_PATH=""

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
        --backup-dir)
            BACKUP_DIR="$2"
            shift
            ;;
        --usb-path)
            USB_PATH="$2"
            shift
            ;;
        --encrypt)
            ENCRYPT=true
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

    mkdir -p "$BACKUP_DIR"
    echo "Backing up keys to $BACKUP_DIR..."

    generate_gpg_key
    generate_ssh_key

    if [[ "$ENCRYPT" == true ]]; then
        encrypt_backups
    fi

    if [[ -n "$USB_PATH" ]]; then
        backup_to_usb "$USB_PATH"
    fi

    echo "Key generation and backup completed!"
}

main "$@"

