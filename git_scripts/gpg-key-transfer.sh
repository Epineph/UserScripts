#!/bin/bash

# Default settings
EXPORT_DIR="$HOME/gpg-exports"
REMOTE_HOST=""
REMOTE_PATH="~/gpg-exports"
KEY_ID=""
EXPORT_PRIVATE=false
ENCRYPT_EXPORT=false

# Function: Show Usage
usage() {
    if command -v bat &>/dev/null; then
        bat --style="grid,header" --paging="never" --color="always" --language="LESS" <<EOF
Usage: $(basename "$0") [OPTIONS]

A script to securely transfer GPG keys between devices via SSH.

Options:
  -k, --key-id <KEY_ID>       GPG key ID to transfer (required).
  -r, --remote <HOST>         Remote SSH host (e.g., user@hostname).
  -p, --path <PATH>           Remote destination path (default: ~/gpg-exports).
  --private                   Include the private key in the export.
  --encrypt                   Encrypt the exported private key.
  -h, --help                  Show this help message.

Examples:
  Export and transfer public key only:
    $(basename "$0") -k ABCDEF1234567890 -r user@remote

  Export private key, encrypt it, and transfer:
    $(basename "$0") -k ABCDEF1234567890 -r user@remote --private --encrypt
EOF
    else
        cat <<EOF
Usage: $(basename "$0") [OPTIONS]

A script to securely transfer GPG keys between devices via SSH.

Options:
  -k, --key-id <KEY_ID>       GPG key ID to transfer (required).
  -r, --remote <HOST>         Remote SSH host (e.g., user@hostname).
  -p, --path <PATH>           Remote destination path (default: ~/gpg-exports).
  --private                   Include the private key in the export.
  --encrypt                   Encrypt the exported private key.
  -h, --help                  Show this help message.

Examples:
  Export and transfer public key only:
    $(basename "$0") -k ABCDEF1234567890 -r user@remote

  Export private key, encrypt it, and transfer:
    $(basename "$0") -k ABCDEF1234567890 -r user@remote --private --encrypt
EOF
    fi
}

# Function: Export Keys
export_keys() {
    mkdir -p "$EXPORT_DIR"
    echo "Exporting public key..."
    gpg --export --armor "$KEY_ID" >"$EXPORT_DIR/public-key.asc"

    if $EXPORT_PRIVATE; then
        echo "Exporting private key..."
        gpg --export-secret-keys --armor "$KEY_ID" >"$EXPORT_DIR/private-key.asc"

        if $ENCRYPT_EXPORT; then
            echo "Encrypting private key export..."
            gpg --symmetric --cipher-algo AES256 "$EXPORT_DIR/private-key.asc"
            rm "$EXPORT_DIR/private-key.asc"
            echo "Private key encrypted as private-key.asc.gpg."
        fi
    fi
    echo "Keys exported to $EXPORT_DIR."
}

# Function: Transfer Keys
transfer_keys() {
    echo "Transferring keys to $REMOTE_HOST:$REMOTE_PATH..."
    ssh "$REMOTE_HOST" "mkdir -p $REMOTE_PATH"
    scp "$EXPORT_DIR/public-key.asc" "$REMOTE_HOST:$REMOTE_PATH/"
    if $EXPORT_PRIVATE; then
        if $ENCRYPT_EXPORT; then
            scp "$EXPORT_DIR/private-key.asc.gpg" "$REMOTE_HOST:$REMOTE_PATH/"
        else
            scp "$EXPORT_DIR/private-key.asc" "$REMOTE_HOST:$REMOTE_PATH/"
        fi
    fi
    echo "Keys transferred successfully to $REMOTE_HOST:$REMOTE_PATH."
}

# Function: Clean Up
cleanup() {
    echo "Cleaning up local exported keys..."
    rm -rf "$EXPORT_DIR"
    echo "Local cleanup complete."
}

# Parse Arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
    -k | --key-id)
        KEY_ID="$2"
        shift
        ;;
    -r | --remote)
        REMOTE_HOST="$2"
        shift
        ;;
    -p | --path)
        REMOTE_PATH="$2"
        shift
        ;;
    --private)
        EXPORT_PRIVATE=true
        ;;
    --encrypt)
        ENCRYPT_EXPORT=true
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

# Validate Inputs
if [[ -z "$KEY_ID" || -z "$REMOTE_HOST" ]]; then
    echo "Error: --key-id and --remote are required."
    usage
    exit 1
fi

# Execute
export_keys
transfer_keys
cleanup

