#!/bin/bash

# Paths and filenames
GIT_INFO_DIR="$HOME/.git_info"
GIT_INFO_FILE="$GIT_INFO_DIR/git_info.enc"
SSH_KEY="$HOME/.ssh/id_ed25519"

# Ensure the .git_info directory exists
mkdir -p "$GIT_INFO_DIR"

# Function to install required packages
function install_pkgs() {
    local needed_pkgs=("gnupg" "openssh" "git")
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

# Function to generate GPG key
function generate_gpg_key() {
    echo "Generating a new GPG key..."
    gpg --full-generate-key

    echo "Listing your GPG keys..."
    gpg --list-secret-keys --keyid-format=long

    echo "Enter the GPG key ID (long form) you'd like to use for signing commits:"
    read -r GPG_KEY_ID

    echo "Would you like to sign all commits by default? (y/n)"
    read -r SIGN_ALL_COMMITS

    if [ "$SIGN_ALL_COMMITS" = "y" ]; then
        git config --global commit.gpgsign true
    fi

    echo "$GPG_KEY_ID"
}

# Function to generate SSH key
function generate_ssh_key() {
    if [ -f "$SSH_KEY" ]; then
        echo "SSH key exists. Generate a new one and backup the old? (y/n): "
        read yn
        case $yn in
            [Yy]* )
                BACKUP_DIR="$HOME/.ssh_backup"
                mkdir -p "$BACKUP_DIR" || { echo "Failed to create backup directory. Exiting."; exit 1; }
                rsync -av --progress "$HOME/.ssh/" "$BACKUP_DIR/" && rm -f "$SSH_KEY"*
                echo "Old SSH key backed up. Proceeding to generate a new one."
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

    ssh-keygen -t ed25519 -C "$(git config user.email)" -f "$SSH_KEY"
    ssh-add "$SSH_KEY"
}

# Function to save git info securely
function save_git_info() {
    local encrypted_info_dir=$GIT_INFO_DIR
    local username="$1"
    local email="$2"
    local gpg_key_id="$3"
    if [ ! -d "$encrypted_info_dir" ]; then
        echo "$encypted_info_dir not found. Creating it..."
        mkdir -p $encrypted_info_dir
    fi

    echo "Saving Git configuration information..."

    echo -e "username=$username\nemail=$email\ngpg_key_id=$gpg_key_id" > "$GIT_INFO_DIR/git_info.txt"
    sudo gpg --symmetric --cipher-algo AES256 -o "$GIT_INFO_FILE" "$GIT_INFO_DIR/git_info.txt"
    rm -f "$GIT_INFO_DIR/git_info.txt"
}

# Function to display SSH and GPG keys for GitHub
function display_keys_for_github() {
    echo "Copy the following SSH public key and add it to your GitHub account:"
    echo "--------------------------------------------------------------------------------"
    cat "${SSH_KEY}.pub"
    echo "--------------------------------------------------------------------------------"

    echo "Here is your GPG key in the format needed for GitHub:"
    echo "--------------------------------------------------------------------------------"
    gpg --armor --export "$GPG_KEY_ID"
    echo "--------------------------------------------------------------------------------"
}

# Main function
function main() {
    install_pkgs

    read -r -p "Enter your git username:" GIT_USERNAME
    sleep 1
    read -r -p "Enter your Git email address:" GIT_EMAIL
    sleep 1
    GPG_KEY_ID=$(generate_gpg_key)
    generate_ssh_key

    save_git_info "$GIT_USERNAME" "$GIT_EMAIL" "$GPG_KEY_ID"

    display_keys_for_github

    echo "Configuration completed. Your Git info has been securely stored."
}

main

