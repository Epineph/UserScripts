#!/bin/bash

# Description of the script
# This script automates the configuration of Git with a GPG key and an SSH key for secure commit signing
# and GitHub authentication. It:
# - Accepts Git username, email, SSH email, and a GPG passphrase file as arguments.
# - Supports a `--noconfirm` mode for fully automated execution.
# - Decrypts a GPG-encrypted file to retrieve the GPG key passphrase securely.
# - Shreds the decrypted passphrase immediately after use.

# Display help section
show_help() {
    cat << EOF
Usage: ./git_generate_ssh_gpg.sh [OPTIONS]

Options:
  --username <GIT_USERNAME>    Git username.
  --email <GIT_EMAIL>          Git email address.
  --ssh-email <SSH_EMAIL>      Email address for SSH key generation.
  --passphrase-file <FILE>     GPG-encrypted file containing the passphrase for the GPG key.
  --noconfirm                  Automatically accept all prompts.
  -h, --help                   Display this help message.

Description:
This script configures Git with GPG signing and SSH keys for GitHub integration.
It supports fully automated execution using the `--noconfirm` flag and a pre-encrypted
GPG passphrase file.

Steps performed:
1. Configures Git username and email.
2. Generates a new GPG key programmatically and retrieves its key ID.
3. Backs up existing SSH keys, generates a new SSH key, and starts the SSH agent.
4. Provides instructions to add the SSH key to GitHub.

EOF
}

# Function to decrypt GPG passphrase
decrypt_passphrase() {
    local passphrase_file="$1"
    if [[ ! -f "$passphrase_file" ]]; then
        echo "Error: Passphrase file not found: $passphrase_file"
        exit 1
    fi

    # Create a temporary file for decrypted passphrase
    local decrypted_file=$(mktemp)

    # Decrypt passphrase into the temporary file
    gpg --quiet --decrypt "$passphrase_file" > "$decrypted_file" 2>/dev/null

    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to decrypt passphrase file."
        rm -f "$decrypted_file"
        exit 1
    fi

    # Read passphrase into a variable
    local passphrase
    passphrase=$(cat "$decrypted_file")

    # Shred and remove the temporary file
    shred -u "$decrypted_file"

    # Return the passphrase
    echo "$passphrase"
}

# Function to generate a GPG key programmatically
generate_gpg_key() {
    echo "Generating a new GPG key programmatically..."

    # Decrypt passphrase if provided
    if [[ -n "$PASSPHRASE_FILE" ]]; then
        PASSPHRASE=$(decrypt_passphrase "$PASSPHRASE_FILE")
    else
        PASSPHRASE=""
    fi

    # Create a GPG configuration file
    GPG_CONFIG=$(mktemp)
    cat > "$GPG_CONFIG" <<EOF
%echo Generating GPG key
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: $GIT_USERNAME
Name-Email: $GIT_EMAIL
Expire-Date: 2y
Passphrase: $PASSPHRASE
%commit
%echo Done
EOF

    # Generate the GPG key using the configuration file
    gpg --batch --gen-key "$GPG_CONFIG"
    rm -f "$GPG_CONFIG"

    # Retrieve the newly created GPG key ID
    echo "Retrieving the newly created GPG key ID..."
    GPG_KEY_ID=$(gpg --list-secret-keys --keyid-format=long | grep 'sec' | head -n 1 | awk '{print $2}' | cut -d '/' -f2)

    if [[ -z "$GPG_KEY_ID" ]]; then
        echo "Error: Unable to retrieve GPG key ID. Exiting."
        exit 1
    fi

    echo "Your new GPG key ID is: $GPG_KEY_ID"
    echo "You can add this to your .zshrc file as follows:"
    echo "export GPG_TTY=\$(tty)"
    echo "export GIT_SIGNING_KEY=$GPG_KEY_ID"

    git config --global user.signingkey "$GPG_KEY_ID"

    if [[ "$NOCONFIRM" == true ]]; then
        git config --global commit.gpgsign true
    else
        echo "Would you like to sign all commits by default? (y/n)"
        read -r SIGN_ALL_COMMITS
        if [ "$SIGN_ALL_COMMITS" = "y" ]; then
            git config --global commit.gpgsign true
        fi
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
        if [[ "$NOCONFIRM" == true ]]; then
            yn="y"
        else
            echo "SSH key exists. Generate a new one and backup the old? (y/n): "
            read yn
        fi
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

    ssh-keygen -t rsa -b 4096 -C "$SSH_EMAIL" -f "$SSH_KEY" -N ""

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

# Parse arguments
GIT_USERNAME=""
GIT_EMAIL=""
SSH_EMAIL=""
PASSPHRASE_FILE=""
NOCONFIRM=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --username)
            GIT_USERNAME="$2"
            shift 2
            ;;
        --email)
            GIT_EMAIL="$2"
            shift 2
            ;;
        --ssh-email)
            SSH_EMAIL="$2"
            shift 2
            ;;
        --passphrase-file)
            PASSPHRASE_FILE="$2"
            shift 2
            ;;
        --noconfirm)
            NOCONFIRM=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Main function
main() {
    if [[ -z "$GIT_USERNAME" || -z "$GIT_EMAIL" || -z "$SSH_EMAIL" ]]; then
        echo "Error: Missing required arguments."
        show_help
        exit 1
    fi

    git config --global user.name "$GIT_USERNAME"
    git config --global user.email "$GIT_EMAIL"

    generate_gpg_key
    generate_ssh_key
}

main
