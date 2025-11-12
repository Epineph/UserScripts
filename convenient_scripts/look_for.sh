#!/bin/bash

# Function to check if a command exists
command_exists() {
    type "$1" &> /dev/null
}

# Function to display help
show_help() {
    cat << EOF
Usage: $0 <path> [OPTIONS]

Search for files within a specified directory based on various criteria and optionally edit or view them.

OPTIONS:
  --ext=<extension>     Search for files with the specified extension (e.g., .sh, .py).
  -s, --script          Search for shell scripts (bash, zsh) and Python scripts.
  --fzf                 Use fzf to interactively select files (if installed).
  -P, --plain-text      Output the contents of the matched files directly without paging (uses bat or cat).
  -N, --no-paging       Similar to --plain-text but with the option to use bat without paging.
  -e, --edit [editor]   Open the matched files in the specified editor. 
                        Defaults to nvim/neovim, vim, or nano if no editor is specified.

EXAMPLES:
  1. Search for .sh and .py files recursively:
     $0 /path/to/search --ext=.sh --ext=.py

  2. Search for shell scripts and Python scripts:
     $0 /path/to/search --script

  3. Use fzf to interactively select files and preview them with bat:
     $0 /path/to/search --ext=.sh --fzf

  4. Output the contents of .sh files without paging:
     $0 /path/to/search --ext=.sh --plain-text

  5. Edit .sh files in vim:
     $0 /path/to/search --ext=.sh --edit vim

NOTES:
- If fd is installed, it will be used for faster searching.
- If fzf is installed, use --fzf for interactive selection.
- If bat is installed, it will be used for preview and plain-text output; otherwise, cat will be used.
- The script tries to use nvim/neovim, vim, or nano as editors, in that order of preference.

EOF
}

# Function to determine the editor to use
determine_editor() {
    if [[ -n "$1" ]]; then
        echo "$1"
    elif command_exists nvim || command_exists neovim; then
        echo "nvim"
    elif command_exists vim; then
        echo "vim"
    elif command_exists nano; then
        echo "nano"
    else
        echo "nano"
    fi
}

# Initialize variables
SEARCH_PATH=""
EXTENSIONS=()
SCRIPT_SEARCH=false
USE_FZF=false
PLAIN_TEXT=false
NO_PAGING=false
EDIT=false
EDITOR=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --ext=*)
            EXTENSIONS+=("${1#*=}")
            ;;
        -s|--script)
            SCRIPT_SEARCH=true
            ;;
        --fzf)
            USE_FZF=true
            ;;
        -P|--plain-text)
            PLAIN_TEXT=true
            ;;
        -N|--no-paging)
            NO_PAGING=true
            ;;
        -e|--edit)
            EDIT=true
            shift
            EDITOR=$(determine_editor "$1")
            if command_exists "$EDITOR"; then
                shift
            else
                EDITOR=$(determine_editor "")
            fi
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            if [[ -z "$SEARCH_PATH" ]]; then
                SEARCH_PATH="$1"
            else
                echo "Unknown option: $1"
                show_help
                exit 1
            fi
            ;;
    esac
    shift
done

# Function to check if a file is a shell or Python script
is_script() {
    local file=$1
    local first_line=$(head -n 1 "$file" 2>/dev/null || echo "")

    case "$first_line" in
        *"/bin/bash"*|*"/usr/bin/env bash"*|*"/bin/sh"*|*"/usr/bin/env sh"*|*"/bin/zsh"*|*"/usr/bin/env zsh"*|*"/usr/bin/env python3"*|*"/usr/bin/env python"*|*"/usr/bin/python3"*|*"/usr/bin/python"*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to process files based on criteria
process_files() {
    local file=$1

    if [[ $SCRIPT_SEARCH == true ]]; then
        is_script "$file" && echo "$file"
    elif [[ -n "${EXTENSIONS[*]}" ]]; then
        for ext in "${EXTENSIONS[@]}"; do
            if [[ "$file" == *"$ext" ]]; then
                echo "$file"
            fi
        done
    fi
}

# Select search tool
if command_exists fd; then
    SEARCH_COMMAND="fd --type f"
    if [[ -n "$SEARCH_PATH" ]]; then
        SEARCH_COMMAND+=" --search-path \"$SEARCH_PATH\""
    fi
else
    if [[ -n "$SEARCH_PATH" ]]; then
        SEARCH_COMMAND="find \"$SEARCH_PATH\" -type f"
    else
        SEARCH_COMMAND="find . -type f"
    fi
fi

# Apply extensions filter to search command
if [[ -n "${EXTENSIONS[*]}" ]]; then
    EXT_FILTER=""
    for ext in "${EXTENSIONS[@]}"; do
        EXT_FILTER+=" --extension ${ext#.}"
    done
    SEARCH_COMMAND+=" $EXT_FILTER"
fi

# Execute search and process files
RESULTS=$(eval "$SEARCH_COMMAND" | while IFS= read -r file; do process_files "$file"; done)

# Filter out empty or null results
RESULTS=$(echo "$RESULTS" | grep -v '^$')

if $USE_FZF && command_exists fzf; then
    if command_exists bat; then
        SELECTED=$(echo "$RESULTS" | fzf --preview 'bat --style=grid --color=always --line-range :500 {}')
    else
        SELECTED=$(echo "$RESULTS" | fzf)
    fi

    if [[ -n "$SELECTED" ]]; then
        if $EDIT; then
            "$EDITOR" "$SELECTED"
        elif $PLAIN_TEXT || $NO_PAGING; then
            if command_exists bat; then
                bat --style=grid --paging=never "$SELECTED"
            else
                cat "$SELECTED"
            fi
        else
            echo "$SELECTED"
        fi
    fi
else
    if $PLAIN_TEXT || $NO_PAGING; then
        if command_exists bat; then
            for file in $RESULTS; do
                bat --style=grid --paging=never "$file"
            done
        else
            for file in $RESULTS; do
                cat "$file"
            done
        fi
    elif $EDIT; then
        for file in $RESULTS; do
            "$EDITOR" "$file"
        done
    else
        echo "$RESULTS"
    fi
fi

