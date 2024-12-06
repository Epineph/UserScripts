#!/bin/bash

# Help Section
cat << EOF
This script helps generate both GPG and SSH keys for GitHub.

Steps Included:
1. Generate a GPG key for signing Git commits and export it.
2. Generate an SSH key to authenticate with GitHub.
3. Provide instructions to add these keys to GitHub.

Usage:
- Run this script, follow the prompts to generate both keys.
- After generating the keys, follow the output to add them to your GitHub account:
  - For GPG key: Go to GitHub > Settings > SSH and GPG keys > New GPG key.
  - For SSH key: Go to GitHub > Settings > SSH and GPG keys > New SSH key.
EOF

# Generate GPG Key
function generate_gpg_key() {
    echo "Generating a new GPG key..."
    gpg --full-generate-key

    # List secret keys and get the GPG key ID
    echo "Listing your GPG keys..."
    gpg --list-secret-keys --keyid-format=long

    # Prompt user to enter the GPG key ID
    echo "Enter the GPG key ID (long form) you'd like to use for signing commits:"
    read -r GPG_KEY_ID

    # Configure Git to use the GPG key for signing commits
    git config --global user.signingkey "$GPG_KEY_ID"

    # Ask if the user wants to sign all commits by default
    echo "Would you like to sign all commits by default? (y/n)"
    read -r SIGN_ALL_COMMITS

    if [ "$SIGN_ALL_COMMITS" = "y" ]; then
      git config --global commit.gpgsign true
    fi

    # Output the GPG key in the format needed for GitHub
    echo "Here is your GPG key in the format needed for GitHub:"
    gpg --armor --export "$GPG_KEY_ID"

    echo "\nTo add your GPG key to GitHub:\n1. Copy the above key.\n2. Go to GitHub > Settings > SSH and GPG keys > New GPG key.\n3. Paste the key and save."
}

# Generate SSH Key
function generate_ssh_key() {
    SSH_KEY="$HOME/.ssh/id_rsa"

    # Check for required packages
    function install_pkgs() {
        local needed_pkgs=("github-cli" "openssh" "git")
        local missing_pkgs=()
        for pkg in "${needed_pkgs[@]}"; do
            if ! pacman -Qi "$pkg" &> /dev/null; then
                missing_pkgs+=("$pkg")
            fi
        done
        if [ ${#missing_pkgs[@]} -ne 0 ]; then
            echo "The following packages are not installed: ${missing_pkgs[*]}"
            read -p "Do you want to install them? (Y/n) " -n 1 -r
            echo    # Move to a new line
            if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
                for package in "${missing_pkgs[@]}"; do
                    yes | sudo pacman -S "$package"
                    if [ $? -ne 0 ]; then
                        echo "Failed to install $package. Aborting."
                        exit 1
                    fi
                done
            else
                echo "The following packages are required to continue: ${missing_pkgs[*]}. Aborting."
                exit 1
            fi
        fi
    }

    install_pkgs

    # Generate SSH key
    if [ -f "$SSH_KEY" ]; then
        echo "SSH key exists. Generate a new one and backup the old? (y/n): "
        read yn
        case $yn in
            [Yy]* )
                # Ask user for backup location choice
                echo "Choose a backup option:"
                echo "1) Default location ($HOME/.ssh_backup)"
                echo "2) Specify another location"
                read -r -p "Enter choice (1/2): " backup_choice

                case $backup_choice in
                    1)
                        BACKUP_DIR="$HOME/.ssh_backup"
                        ;;
                    2)
                        read -r -p "Enter the backup directory path: " custom_backup_dir
                        BACKUP_DIR="$custom_backup_dir"
                        ;;
                    *)
                        echo "Invalid choice. Exiting."
                        exit 1
                        ;;
                esac

                # Create backup directory if it doesn't exist
                mkdir -p "$BACKUP_DIR" || { echo "Failed to create backup directory. Exiting."; exit 1; }

                # Backup and remove existing SSH key
                echo "Backing up existing SSH key to $BACKUP_DIR..."
                rsync -av --progress "$HOME/.ssh/" "$BACKUP_DIR/" && rm -f "$SSH_KEY"*
                ;;
            [Nn]* )
                echo "Exiting.."
                exit 1
                ;;
            *)
                echo "Please answer yes or no."
                exit 1
                ;;
        esac
    else
        echo "No existing SSH key found. Generating a new one."
    fi

    ssh-keygen -t rsa-sha2-512 -b 4096 -C "$USER@$(hostname)" -f "$SSH_KEY"

    # Start the ssh-agent in the background and add your SSH key
    eval "$(ssh-agent -s)"
    ssh-add "$SSH_KEY"

    # Print the public SSH key
    echo "Copy the following SSH public key and add it to your GitHub account:"
    echo "--------------------------------------------------------------------------------"
    cat "${SSH_KEY}.pub"
    echo "--------------------------------------------------------------------------------"

    echo "\nTo add your SSH key to GitHub:\n1. Copy the above key.\n2. Go to GitHub > Settings > SSH and GPG keys > New SSH key.\n3. Paste the key and save."
}

# Main Script Execution
echo "Starting GPG and SSH key generation..."
generate_gpg_key
generate_ssh_key

echo "\nGPG and SSH key generation completed. Follow the instructions above to add them to your GitHub account."
