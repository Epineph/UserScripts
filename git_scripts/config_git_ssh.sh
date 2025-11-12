#!/bin/bash

# Description of the script
# This script automates the configuration of Git with a GPG key and an SSH key for secure commit signing
# and GitHub authentication. It:
# - Prompts the user for Git username and email.
# - Generates a new GPG key for commit signing and exports it in a GitHub-compatible format.
# - Backs up existing SSH keys, generates a new SSH key, and configures the SSH agent.
# - Provides instructions to add the generated SSH key to GitHub.

# Display help section
show_help() {
    cat << EOF
Usage: ./git_generate_ssh_gpg.sh

This script configures Git with GPG signing and SSH keys for GitHub integration.

Steps performed:
1. Prompts for your Git username and email address.
2. Generates a new GPG key for signing Git commits and configures Git to use it.
3. Backs up existing SSH keys, generates a new SSH key, and starts the SSH agent.
4. Provides instructions to add the SSH key to GitHub.

If something is omitted or an error occurs:
- Ensure you provide a valid email address when prompted for GPG and SSH key generation.
- Make sure your environment has GnuPG (gpg), OpenSSH, and Git installed.

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
        show_help
        exit 1
    fi

    git config --global user.signingkey "$GPG_KEY_ID"

    echo "Would you like to sign all commits by default? (y/n)"
    read -r SIGN_ALL_COMMITS

    if [ "$SIGN_ALL_COMMITS" = "y" ]; then
        git config --global commit.gpgsign true
    fi

    echo "GPG key generated and Git configured to use it for signing commits."
    echo "Here is your GPG key in the format needed for GitHub:"
    gpg --armor --export "$GPG_KEY_ID"
}

# Function to generate an SSH key
generate_ssh_key() {
    echo "Generating a new SSH key..."

    SSH_KEY="$HOME/.ssh/id_rsa"

    if [ -f "$SSH_KEY" ]; then
        echo "SSH key exists. Generate a new one and backup the old? (y/n): "
        read yn
        if [ "$yn" == "y" ]; then
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
        show_help
        exit 1
    fi

    ssh-keygen -t rsa -b 4096 -C "$SSH_EMAIL" -f "$SSH_KEY"

    echo "Starting the SSH agent..."
    eval "$(ssh-agent -s)"

    echo "Adding the SSH private key to the SSH agent..."
    ssh-add "$SSH_KEY"

    echo "Here is your SSH public key:"
    cat "${SSH_KEY}.pub"

    echo "To add the SSH key to GitHub, follow these steps:"
    echo "1. Copy the SSH key above."
    echo "2. Go to GitHub and navigate to Settings > SSH and GPG keys > New SSH key."
    echo "3. Paste the SSH key and give it a title."
}

# Main function
main() {
    echo "Enter your Git username:"
    read -r GIT_USERNAME
    if [[ -z "$GIT_USERNAME" ]]; then
        echo "Error: Git username is required."
        show_help
        exit 1
    fi
    git config --global user.name "$GIT_USERNAME"

    echo "Enter your Git email address:"
    read -r GIT_EMAIL
    if [[ -z "$GIT_EMAIL" ]]; then
        echo "Error: Git email address is required."
        show_help
        exit 1
    fi
    git config --global user.email "$GIT_EMAIL"

    generate_gpg_key
    generate_ssh_key
}

if [[ $1 == "--help" || $1 == "-h" ]]; then
    show_help
    exit 0
fi

main

