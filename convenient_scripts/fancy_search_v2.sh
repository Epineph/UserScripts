#!/bin/bash

search_path=""
search_name=""
search_filter=""
use_fzf=false
use_preview=false
preview_style=""
editor=""
search_scripts=false
plain_text=false

# Function to display help
usage() {
    cat << EOF
Usage: $0 --search <path> [OPTIONS]

Search for files within a specified directory based on various criteria and optionally edit or view them.

OPTIONS:
  -s, --search <path>       Specify the directory path to search within.
  -n, --name <name>         Search for files by name (supports wildcards, e.g., *.sh).
  -f, --filter <filter>     Filter search results by type (e.g., "files" for files, "dirs" for directories,
                            or specify an extension like "sh" or "py" to filter by file type).
  --fzf, --fuzzy-finder     Use fzf for fuzzy finding and selecting files interactively.
  -p, --preview             Preview files using bat (if installed) with optional --style.
  --style <style>           Specify bat preview style (e.g., "grid", "numbers", etc.). Defaults to "numbers".
  -e, --edit <editor>       Open the selected file in the specified editor (e.g., vim, nano).
  --script                  Search specifically for shell scripts (bash, sh, zsh) and Python scripts (python, python3).
  --plain-text              Output the contents of found files directly (uses bat if installed, otherwise cat).
  -h, --help                Display this help message.

EXAMPLES:
  1. Search for .sh and .py files recursively:
     $0 --search /path/to/search --name "*.sh" --name "*.py"

  2. Search for shell scripts and Python scripts:
     $0 --search /path/to/search --script

  3. Use fzf to interactively select files and preview them with bat:
     $0 --search /path/to/search --fzf --preview

  4. Output the contents of .sh files without paging:
     $0 --search /path/to/search --name "*.sh" --plain-text

  5. Search for shell scripts and edit the selected file with vim:
     $0 --search /path/to/search --script --fzf --edit vim

NOTES:
- If fd is installed, it will be used for faster searching.
- If fzf is installed, use --fzf for interactive selection.
- If bat is installed, it will be used for preview and plain-text output; otherwise, cat will be used.
- The script tries to use nvim/neovim, vim, or nano as editors, in that order of preference.

EOF
    exit 1
}

# Function to perform the search
perform_search() {
    local path=$1
    local name=$2
    local filter=$3
    local cmd="fd . \"$path\""

    if [[ -n "$name" ]]; then
        cmd+=" --name \"$name\""
    fi

    if $search_scripts; then
        cmd+=" --type f"
        cmd+=" --exec sh -c 'head -n 1 {} | grep -qE \"/bin/(bash|sh|zsh)|/usr/bin/env (bash|sh|zsh|python|python3)\" && echo {}'"
    elif [[ -n "$filter" ]]; then
        case "$filter" in
            "files") cmd+=" -t f" ;;
            "dirs") cmd+=" -t d" ;;
            *) cmd+=" --extension \"$filter\"" ;;
        esac
    fi

    if $use_fzf; then
        cmd+=" | fzf"
    fi

    if $use_preview; then
        cmd+=" --preview 'bat --style=${preview_style:-numbers} {}'"
    fi

    if $plain_text; then
        if command -v bat &>/dev/null; then
            cmd+=" | xargs bat --style=grid --paging=never"
        else
            cmd+=" | xargs cat"
        fi
    fi

    selected_file=$(eval "$cmd")

    if [[ -n "$selected_file" && -n "$editor" ]]; then
        $editor "$selected_file"
    elif [[ -n "$selected_file" ]]; then
        echo "Selected file: $selected_file"
    fi
}

# Parsing command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -s|--search) search_path="$2"; shift ;;
        -n|--name) search_name="$2"; shift ;;
        -f|--filter) search_filter="$2"; shift ;;
        --fzf|--fuzzy-finder) use_fzf=true ;;
        -p|--preview) use_preview=true ;;
        --style) preview_style="$2"; shift ;;
        -e|--edit) editor="$2"; shift ;;
        --script) search_scripts=true ;;
        --plain-text) plain_text=true ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
    shift
done

if [[ -z "$search_path" || ! -d "$search_path" ]]; then
    echo "Error: A valid directory path is required."
    usage
fi

perform_search "$search_path" "$search_name" "$search_filter"

