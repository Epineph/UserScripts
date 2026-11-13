#!/bin/bash

# Default configurations for `bat`
DEFAULT_STYLE="grid"
DEFAULT_THEME="Dracula"
DEFAULT_COLOR="always"
DEFAULT_PAGING="never"
DEFAULT_LANGUAGE="plaintext"
REQUIRED_PACKAGES=("file")

# Ensure bat is available
BAT_COMMAND=$(command -v bat || true)

if [[ -z "$BAT_COMMAND" ]]; then
    echo "bat not found. Falling back to cat." >&2
    BAT_COMMAND="cat"
fi

# Check and prompt for optional packages
check_optional_packages() {
    local missing=()
    for package in "${REQUIRED_PACKAGES[@]}"; do
        if ! command -v "$package" &>/dev/null; then
            missing+=("$package")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "The following optional packages are missing: ${missing[*]}"
        read -p "Do you want to install them now? [Y/n] " choice
        if [[ "$choice" =~ ^[Yy]$ ]] || [[ -z "$choice" ]]; then
            sudo pacman -S "${missing[@]}"
        else
            echo "Optional features will be disabled."
        fi
    fi
}

# Run the optional package check
check_optional_packages

# Function to infer language based on file extension or content
infer_language() {
    local file="$1"

    # Check file extension
    case "${file##*.}" in
        md) echo "markdown" ;;
        sh|zsh|bash) echo "bash" ;;
        py) echo "python" ;;
        js) echo "javascript" ;;
        html) echo "html" ;;
        css) echo "css" ;;
        json) echo "json" ;;
        xml) echo "xml" ;;
        *)
            if command -v file &>/dev/null; then
                file --brief --mime-type "$file" | grep -oE "text/(x-)?[a-z]+" | sed 's|text/||'
            else
                echo "$DEFAULT_LANGUAGE"
            fi
            ;;
    esac
}

# Wrapper logic
bat_wrapper() {
    local style="$DEFAULT_STYLE"
    local theme="$DEFAULT_THEME"
    local color="$DEFAULT_COLOR"
    local paging="$DEFAULT_PAGING"
    local language="$DEFAULT_LANGUAGE"
    local additional_args=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --style=*) style="${1#*=}" ;;
            --theme=*) theme="${1#*=}" ;;
            --color=*) color="${1#*=}" ;;
            --paging=*) paging="${1#*=}" ;;
            --language=*) language="${1#*=}" ;;
            -*)
                additional_args+=("$1")
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    if [ -t 0 ]; then
        local file="$1"
        if [[ -d "$file" ]]; then
            echo "Error: '$file' is a directory. Please provide a valid file." >&2
            return 1
        elif [[ -f "$file" ]]; then
            language=$(infer_language "$file")
            "$BAT_COMMAND" --style="$style" --theme="$theme" --color="$color" --paging="$paging" --language="$language" "${additional_args[@]}" "$file"
        else
            echo "Error: '$file' is not a valid file." >&2
            return 1
        fi
    else
        "$BAT_COMMAND" --style="$style" --theme="$theme" --color="$color" --paging="$paging" --language="$language" "${additional_args[@]}"
    fi
}

# Main entry point
bat_wrapper "$@"

