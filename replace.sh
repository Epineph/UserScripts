#!/bin/bash

# Function to show help
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]... file_path
Backs up and replaces files, optionally allowing editing.

Arguments:
  file_path            Path to the file or directory to be replaced.

Options:
  --help               Show this help message and exit.
  -e, --edit           Specify the editor to use (nano, vim, nvim, vi, etc.).
  --fzf                Use fzf to select multiple files.

Examples:
  $(basename "$0") /path/to/file
  $(basename "$0") -e vim /path/to/file
  $(basename "$0") --fzf /path/to/directory
EOF
}

# Function to back up a file
backup_file() {
    local file_path="$1"
    local backup_dir="$HOME/.backup_scripts"
    local file_name=$(basename "$file_path")
    local backup_name="$backup_dir/$file_name.backup"

    mkdir -p "$backup_dir"

    if [[ -f "$backup_name" ]]; then
        local count=1
        while [[ -f "$backup_name.$count" ]]; do
            ((count++))
        done
        backup_name="$backup_name.$count"
    fi

    cp "$file_path" "$backup_name"
    echo "Backup of $file_path created at $backup_name"
}

# Function to edit a file
edit_file() {
    local file_path="$1"
    local editor="$2"

    if [[ -n "$editor" ]]; then
        sudo $editor "$file_path"
    else
        sudo vim "$file_path"
    fi
}

# Function to use fzf to select files
fzf_edit() {
    local editor="$1"
    local bat_style='--color=always --line-range :500 --style=grid'

    local files
    files=$(fd --type f . | fzf --multi --preview "bat $bat_style {}" --preview-window=right:60%:wrap)

    if [[ -n "$files" ]]; then
        for file in $files; do
            replace_file "$file" "$editor"
        done
    fi
}

# Function to replace a file
replace_file() {
    local file_path="$1"
    local editor="$2"

    backup_file "$file_path"
    rm "$file_path"
    touch "$file_path"
    edit_file "$file_path" "$editor"
}

# Parse command-line options
editor=""
use_fzf=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--edit)
            editor="$2"
            shift 2
            ;;
        --fzf)
            use_fzf=true
            shift
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            file_path="$1"
            shift
            ;;
    esac
done

# Main logic
if [[ "$use_fzf" == true ]]; then
    if [[ -d "$file_path" ]]; then
        cd "$file_path" || exit 1
        fzf_edit "$editor"
    else
        fzf_edit "$editor"
    fi
elif [[ -n "$file_path" && -f "$file_path" ]]; then
    replace_file "$file_path" "$editor"
elif [[ -n "$file_path" && -d "$file_path" ]]; then
    cd "$file_path" || exit 1
    fzf_edit "$editor"
else
    show_help
    exit 1
fi
