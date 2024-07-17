#!/bin/bash

# Function to display usage information
usage() {
    cat << EOF
Usage: $0 [-p | --paste-clipboard] <script_file>

Options:
  -p, --paste-clipboard    Clear the script file and replace its content with the clipboard content.
  -h, --help               Display this help message and exit.

Description:
  This script clears the content of the specified script file. If the -p or --paste-clipboard option
  is provided, it replaces the content of the file with the current clipboard content. Otherwise, it
  leaves the file empty.

Requirements:
  This script requires either xclip or xsel to be installed for clipboard operations.

Examples:
  Clear the content of my_script.sh:
    $0 my_script.sh

  Clear the content of my_script.sh and replace it with clipboard content:
    $0 -p my_script.sh

EOF
    exit 1
}

# Check if xclip or xsel is installed
check_clipboard_tool() {
    if command -v xclip &> /dev/null; then
        echo "xclip"
    elif command -v xsel &> /dev/null; then
        echo "xsel"
    else
        echo "Error: xclip or xsel is required to paste from clipboard." >&2
        exit 1
    fi
}

# Parse command line arguments
paste_clipboard=false
script_file=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--paste-clipboard)
            paste_clipboard=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            script_file="$1"
            shift
            ;;
    esac
done

# Validate script file argument
if [[ -z "$script_file" ]]; then
    usage
fi

# Clear the content of the script file
> "$script_file"

# Paste clipboard content if -p or --paste-clipboard is provided
if $paste_clipboard; then
    clipboard_tool=$(check_clipboard_tool)
    if [[ "$clipboard_tool" == "xclip" ]]; then
        xclip -o > "$script_file"
    elif [[ "$clipboard_tool" == "xsel" ]]; then
        xsel --clipboard --output > "$script_file"
    fi
fi

echo "Script file '$script_file' has been reset."

