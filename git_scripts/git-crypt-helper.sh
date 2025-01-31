#!/bin/bash

# Default Backup Location
DEFAULT_BACKUP_DIR="$HOME/git-crypt-backups"

# Variables
TARGET=""
CUSTOM_BACKUP_LOCATIONS=()
TARBALL=false
ENCRYPT=false

# Colors for help (fallback-safe)
GREEN="\e[32m"
CYAN="\e[36m"
RESET="\e[0m"

# Function: Show Usage
usage() {
    if command -v bat &>/dev/null; then
        bat --style="grid,header" --paging="never" --color="always" --language="LESS" --theme="Dracula" <<EOF
Usage: $(basename "$0") [OPTIONS]

A script to manage git-crypt and GPG key backups with flexibility.

Options:
  -t, --target <PATH>                 Target file/directory to act upon (e.g., repository or config file).
  -b, --backup-loc <PATH>             Custom backup location(s). Multiple allowed.
  --tarball                           Create a tar.gz of all backup files.
  --encrypt                           Encrypt the tarball with GPG.
  -h, --help                          Show this help message.

Examples:
  Backup GPG and git-crypt keys for a repository:
    $(basename "$0") -t ~/repos/my_repo

  Backup to multiple locations:
    $(basename "$0") -t ~/repos/my_repo -b /mnt/usb-drive -b ~/GoogleDrive/backups

  Create a tar.gz and encrypt it:
    $(basename "$0") -t ~/repos/my_repo --tarball --encrypt
EOF
    else
        cat <<EOF
Usage: $(basename "$0") [OPTIONS]

A script to manage git-crypt and GPG key backups with flexibility.

Options:
  -t, --target <PATH>                 Target file/directory to act upon (e.g., repository or config file).
  -b, --backup-loc <PATH>             Custom backup location(s). Multiple allowed.
  --tarball                           Create a tar.gz of all backup files.
  --encrypt                           Encrypt the tarball with GPG.
  -h, --help                          Show this help message.

Examples:
  Backup GPG and git-crypt keys for a repository:
    $(basename "$0") -t ~/repos/my_repo

  Backup to multiple locations:
    $(basename "$0") -t ~/repos/my_repo -b /mnt/usb-drive -b ~/GoogleDrive/backups

  Create a tar.gz and encrypt it:
    $(basename "$0") -t ~/repos/my_repo --tarball --encrypt
EOF
    fi
}

# Function: Backup GPG Key
backup_gpg_key() {
    local backup_dir="$1"
    echo -e "${CYAN}Backing up GPG private key to $backup_dir...${RESET}"
    mkdir -p "$backup_dir"
    gpg --export-secret-keys >"$backup_dir/gpg-private-key-backup.asc"
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}GPG private key backed up successfully.${RESET}"
    else
        echo "Failed to back up GPG private key."
        exit 1
    fi
}

# Function: Backup git-crypt Key
backup_git_crypt_key() {
    local repo="$1"
    local backup_dir="$2"
    if [[ -d "$repo/.git-crypt/keys" ]]; then
        echo -e "${CYAN}Backing up git-crypt symmetric key from $repo...${RESET}"
        cp "$repo/.git-crypt/keys/default" "$backup_dir/git-crypt-symmetric-key"
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}git-crypt symmetric key backed up to $backup_dir.${RESET}"
        else
            echo "Failed to back up git-crypt symmetric key."
            exit 1
        fi
    else
        echo "git-crypt keys not found in $repo. Make sure it's a git-crypt-enabled repository."
        exit 1
    fi
}

# Function: Create and Encrypt Tarball
create_tarball() {
    local backup_dir="$1"
    local tarball_path="$backup_dir/git-crypt-backups.tar.gz"
    echo -e "${CYAN}Creating tarball of backup files in $backup_dir...${RESET}"
    tar -czf "$tarball_path" -C "$backup_dir" .
    echo -e "${GREEN}Tarball created at $tarball_path.${RESET}"

    if $ENCRYPT; then
        echo -e "${CYAN}Encrypting tarball...${RESET}"
        gpg --symmetric --cipher-algo AES256 "$tarball_path"
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}Encrypted tarball created: $tarball_path.gpg${RESET}"
        else
            echo "Failed to encrypt tarball."
            exit 1
        fi
    fi
}

# Parse Arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
    -t | --target)
        TARGET="$2"
        shift
        ;;
    -b | --backup-loc)
        CUSTOM_BACKUP_LOCATIONS+=("$2")
        shift
        ;;
    --tarball)
        TARBALL=true
        ;;
    --encrypt)
        ENCRYPT=true
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
    shift
done

# Validate Target
if [[ -z "$TARGET" ]]; then
    echo "Error: --target is required."
    usage
    exit 1
fi

# Backup Locations
BACKUP_DIRS=("${CUSTOM_BACKUP_LOCATIONS[@]:-$DEFAULT_BACKUP_DIR}")

# Perform Actions
for BACKUP_DIR in "${BACKUP_DIRS[@]}"; do
    backup_gpg_key "$BACKUP_DIR"
    backup_git_crypt_key "$TARGET" "$BACKUP_DIR"
done

if $TARBALL; then
    for BACKUP_DIR in "${BACKUP_DIRS[@]}"; do
        create_tarball "$BACKUP_DIR"
    done
fi

