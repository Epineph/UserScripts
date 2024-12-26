#!/bin/bash

# Paths and filenames
GIT_INFO_DIR="$HOME/.git_info"
GIT_INFO_FILE="$GIT_INFO_DIR/git_info.enc"
ZSH_GIT_FILE="$HOME/.zsh_profile/zsh_git.zsh"
SSH_KEY="$HOME/.ssh/id_rsa"

# Ensure the .git_info directory exists
mkdir -p "$GIT_INFO_DIR"

# Function to display help
function show_help() {
    cat << EOF
Usage: $(basename "$0") [options]

This script automates the setup of Git, SSH, and GPG keys for GitHub. It can generate and configure GPG keys for signing Git commits, generate SSH keys, and securely store your Git configuration (username, email, and GPG key ID) using encryption.

Options:
  -e, --encrypt     Encrypt the Git configuration.
  -h, --help        Show this help message and exit.

EOF
}

# Function to install required packages
function install_pkgs() {
    local needed_pkgs=("gnupg" "openssh" "git" "github-cli")
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
    local email="$1"

    if [ -f "$SSH_KEY" ]; then
        echo "SSH key exists. Generate a new one and backup the old? (y/n): "
        read yn
        case $yn in
            [Yy]* )
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

                mkdir -p "$BACKUP_DIR" || { echo "Failed to create backup directory. Exiting."; exit 1; }

                echo "Backing up existing SSH key to $BACKUP_DIR..."
                rsync -av --progress "$HOME/.ssh/" "$BACKUP_DIR/" && rm -f "$SSH_KEY"*

                echo "Old SSH key backed up. Proceeding to generate a new one."
                ssh-keygen -t rsa-sha2-512 -b 4096 -f "$SSH_KEY" -C "$email"
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
        ssh-keygen -t rsa-sha2-512 -b 4096 -f "$SSH_KEY" -C "$email"
    fi

    # Start the ssh-agent in the background and add your SSH key
    eval "$(ssh-agent -s)"
    ssh-add "$SSH_KEY"

    echo "Copy the following SSH public key and add it to your GitHub account:"
    echo "--------------------------------------------------------------------------------"
    cat "${SSH_KEY}.pub"
    echo "--------------------------------------------------------------------------------"

    # Add the key to GitHub using gh
    gh ssh-key add --title "SSH Key" --type authentication "$SSH_KEY.pub"
}

# Function to save git info securely
function save_git_info() {
    local username="$1"
    local email="$2"
    local gpg_key_id="$3"

    echo "Saving Git configuration information..."

    echo -e "GIT_USERNAME=\"$username\"\nGIT_USER_EMAIL=\"$email\"\nGIT_GPG_ID=\"$gpg_key_id\"" > "$GIT_INFO_DIR/git_info.txt"
    gpg --symmetric --cipher-algo AES256 -o "$GIT_INFO_FILE" "$GIT_INFO_DIR/git_info.txt"
    rm -f "$GIT_INFO_DIR/git_info.txt"
}

# Function to configure GitHub CLI (gh)
function configure_gh() {
    gh config set git_protocol ssh
    gh config set browser firefox
    gh config set pager never
    gh config set editor nvim
    gh config set prompt enabled
    gh config set prefer_editor_prompt enabled

    # Add GPG and SSH keys to GitHub using gh CLI
    gh gpg-key add --title "GPG Key" <(gpg --armor --export "$GPG_KEY_ID")
}

# Function to update the zsh file with the configurations
function update_zsh_file() {
    local git_username="$1"
    local git_user_email="$2"
    local git_gpg_keyid="$3"
    local encrypt="$4"

    if [[ $encrypt -eq 1 ]]; then
        cat << EOF > "$ZSH_GIT_FILE"
# $HOME/.zsh_profile/zsh_git.zsh

function load_git_config() {
    if [[ -f "$GIT_INFO_FILE" ]]; then
        eval \$(gpg --decrypt "$GIT_INFO_FILE" 2>/dev/null | sed 's/^/export /')
    fi
}

load_git_config

gitconf() {
    git config --global user.name "\$GIT_USERNAME"
    git config --global user.email "\$GIT_USER_EMAIL"
    git config --global user.signingkey "\$GIT_GPG_ID"
    git config --global commit.gpgsign true
    git config --global color.ui auto
    git config --global init.defaultBranch main
}

gitconf
EOF
    else
        cat << EOF > "$ZSH_GIT_FILE"
# $HOME/.zsh_profile/zsh_git.zsh

export GIT_USERNAME="$git_username"
export GIT_USER_EMAIL="$git_user_email"
export GIT_GPG_ID="$git_gpg_keyid"

gitconf() {
    git config --global user.name "\$GIT_USERNAME"
    git config --global user.email "\$GIT_USER_EMAIL"
    git config --global user.signingkey "\$GIT_GPG_ID"
    git config --global commit.gpgsign true
    git config --global color.ui auto
    git config --global init.defaultBranch main
}

gitconf
EOF
    fi

    echo ".zsh file has been updated with the Git configuration."
}

# Main function
function main() {
    local encrypt=0

    while [[ "$1" ]]; do
        case "$1" in
            -e|--encrypt)
                encrypt=1
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "Invalid option: $1"
                show_help
                return 1
                ;;
        esac
    done

    install_pkgs

    read -r -p "Enter your git username:" GIT_USERNAME
    sleep 1
    read -r -p "Enter your Git email address:" GIT_EMAIL
    sleep 1

    GPG_KEY_ID=$(generate_gpg_key)
    generate_ssh_key "$GIT_USER_EMAIL"

    if [[ $encrypt -eq 1 ]]; then
        save_git_info "$GIT_USERNAME" "$GIT_USER_EMAIL" "$GPG_KEY_ID"
    fi

    update_zsh_file "$GIT_USERNAME" "$GIT_USER_EMAIL" "$GPG_KEY_ID" "$encrypt"
    configure_gh

    echo "Configuration completed. Your Git info has been securely stored."
}

main "$@"

