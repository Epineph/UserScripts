#!/bin/bash
#
# SSH Key Manager
# This script starts ssh-agent if not running, then adds a selected private key with a timeout.
# Allows exporting public keys.
#
# Usage:
#   ssh_key_manager.sh [-t 30m] [keyname or full_path] [--export --public-key]
#
# - If no key is given, it searches in ~/.ssh/
# - If one key is found, it is added automatically
# - If multiple keys exist, fzf allows choosing a key
# - Supports setting expiration time (-t)
# - Exports the public key if --export is used
#

SSH_DIR="$HOME/.ssh"
SSH_AGENT_TIMEOUT=""
EXPORT_PUBLIC_KEY=false
KEY_PATH=""

# Function to parse time (-t)
parse_time() {
    local time_str="$1"
    local total_seconds=0
    local num

    while [[ "$time_str" =~ ([0-9]+)([smh]) ]]; do
        num="${BASH_REMATCH[1]}"
        case "${BASH_REMATCH[2]}" in
            s) total_seconds=$((total_seconds + num)) ;;
            m) total_seconds=$((total_seconds + num * 60)) ;;
            h) total_seconds=$((total_seconds + num * 3600)) ;;
        esac
        time_str="${time_str/${BASH_REMATCH[0]}/}"
    done

    echo "$total_seconds"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t)
            shift
            [[ -n "$1" ]] && SSH_AGENT_TIMEOUT=$(parse_time "$1")
            shift
            ;;
        --export|--public-key)
            EXPORT_PUBLIC_KEY=true
            shift
            ;;
        *)
            KEY_PATH="$1"
            shift
            ;;
    esac
done

# Ensure ssh-agent is running
if ! pgrep -u "$USER" ssh-agent > /dev/null; then
    eval "$(ssh-agent -s)" >/dev/null
fi

# Find private keys if no key is specified
if [[ -z "$KEY_PATH" ]]; then
    KEYS=($(find "$SSH_DIR" -type f \( -name "id_rsa" -o -name "id_ecdsa" -o -name "id_ed25519" -o -name "id_dsa" \) ! -name "*.pub" 2>/dev/null))

    if [[ ${#KEYS[@]} -eq 1 ]]; then
        KEY_PATH="${KEYS[0]}"
    elif [[ ${#KEYS[@]} -gt 1 ]]; then
        echo "Multiple keys found. Select one:"
        KEY_PATH=$(printf "%s\n" "${KEYS[@]}" | fzf)
    else
        echo "No private keys found in $SSH_DIR"
        exit 1
    fi
elif [[ ! -f "$KEY_PATH" ]]; then
    echo "Specified key does not exist: $KEY_PATH"
    exit 1
fi

# Add the selected key to ssh-agent
if [[ -n "$SSH_AGENT_TIMEOUT" ]]; then
    ssh-add -t "$SSH_AGENT_TIMEOUT" "$KEY_PATH"
else
    ssh-add "$KEY_PATH"
fi

echo "Added SSH key: $KEY_PATH"

# Export the public key if requested
if $EXPORT_PUBLIC_KEY; then
    PUB_KEY="${KEY_PATH}.pub"
    if [[ -f "$PUB_KEY" ]]; then
        echo "Public Key:"
        cat "$PUB_KEY"
    else
        echo "No public key found for $KEY_PATH"
    fi
fi

