#!/bin/bash

SSH_KEY="$HOME/.ssh/id_rsa"

# Generate a new GPG key
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


echo "GPG key generated and Git configured to use it for signing commits."




function main() {
    local email=""
    install_pkgs
    if [[ $# -eq 0 ]]; then
        >&2 echo "No arguments provided"
        echo "To generate ssh-key, input your email-adress :"
        read answer
        if [[ -z $answer ]]; then
            echo "aborting"
        else
            email=$answer
        fi
    fi
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
                        read -p -r "Enter the backup directory path: " custom_backup_dir
                        BACKUP_DIR="$custom_backup_dir"
                        ;;
                    *)
                        echo "Invalid choice. Exiting."
                        exit 1
                        ;;
                esac

            # Create backup directory if it doesn't exist
            mkdir -p "$BACKUP_DIR" || { echo "Failed to create backup directory. Exiting."; e
xit 1; }

            # Backup and remove existing SSH key
            echo "Backing up existing SSH key to $BACKUP_DIR..."
            # Here you can use rsync or cp command to backup the .ssh directory
            rsync -av --progress "$HOME/.ssh/" "$BACKUP_DIR/" && rm -f "$SSH_KEY"*

            echo "Old SSH key backed up. Proceeding to generate a new one."
            # Your command to generate a new SSH key goes here
            # ssh-keygen -t rsa -b 4096 -f "$SSH_KEY"
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
    # Your command to generate a new SSH key goes here if one doesn't already exist
    # ssh-keygen -t rsa -b 4096 -f "$SSH_KEY"
    fi
    ssh-keygen -t rsa-sha2-512 -b 4096 -C "$answer" -f "$SSH_KEY"


}




main "$@"
# Start the ssh-agent in the background and add your SSH key
eval "$(ssh-agent -s)"
ssh-add "$SSH_KEY"

# Output the GPG key in the format needed for GitHub
echo "Here is your GPG key in the format needed for GitHub:"
gpg --armor --export "$GPG_KEY_ID"

# Print the public SSH key
echo "Copy the following SSH public key and add it to your GitHub account:"
echo "--------------------------------------------------------------------------------"
cat "${SSH_KEY}.pub"
echo "--------------------------------------------------------------------------------"
