#!/bin/bash

search_path=""
search_name=""
search_filter=""
use_fzf=false
use_preview=false
preview_style=""
editor=""

# Function to display help
usage() {
    echo "Usage: $0 --search <path> [-n|--name <name>] [-f|--filter] [-fzf|--fuzzy-finder] [-p|--preview] [-e|--edit <editor>]"
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

    if [[ -n "$filter" ]]; then
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

    selected_file=$(eval "$cmd")

    if [[ -n "$selected_file" && -n "$editor" ]]; then
        $editor "$selected_file"
    else
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
        *) usage ;;
    esac
    shift
done

if [[ -z "$search_path" || ! -d "$search_path" ]]; then
    echo "Error: A valid directory path is required."
    usage
fi

perform_search "$search_path" "$search_name" "$search_filter"
