#!/bin/bash

# Define the directory containing the modular zshrc files
ZSHRC_DIR="$HOME/.zshrc-setup"

# Define the editor to use
EDITOR=${EDITOR:-vim}

# Function to get the full path of a zshrc file
get_zshrc_file() {
    local file=$1
    echo "$ZSHRC_DIR/$file.zsh"
}

# Function to perform actions on the zshrc files
manage_zshrc() {
    local action=$1
    local file=$2

    case $action in
        vim)
            $EDITOR "$(get_zshrc_file "$file")"
            ;;
        cat)
            cat "$(get_zshrc_file "$file")"
            ;;
        bat)
            bat --style=grid "$(get_zshrc_file "$file")"
            ;;
        *)
            echo "Usage: $0 {vim|cat|bat} {zsh|path|theme|plugins|functions|aliases|history|environment}"
            ;;
    esac
}

# Check the number of arguments
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 {vim|cat|bat} {zsh|path|theme|plugins|functions|aliases|history|environment}"
    exit 1
fi

# Call the manage_zshrc function with the provided arguments
manage_zshrc $1 $2

