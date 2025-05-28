#!/usr/bin/env bash

#===============================================================================
# Script Name   : edit_empty.sh
# Description   : Backs up a script, empties it, and opens it in an editor.
# Author        : Epineph (with ChatGPT)
#===============================================================================

#=============================#
#       HELP SECTION         #
#=============================#
show_help() {
cat << EOF
Usage: ${0##*/} [-e EDITOR] SCRIPT_PATH

Backs up the script to: \$HOME/.logs/scripts/<date>/<time>/<script>.bak,
empties the original file, and opens it with the specified editor.

Options:
  -e, --editor EDITOR     Specify which editor to use. If not provided, uses \$EDITOR.
  -h, --help              Show this help message.

Examples:
  ${0##*/} -e nano my_script.sh
  ${0##*/} my_script.sh
EOF
}

#=============================#
#      PARSE ARGUMENTS       #
#=============================#
editor=""
script_path=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--editor)
            shift
            editor="$1"
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            script_path="$1"
            ;;
    esac
    shift
done

#=============================#
#      VALIDATE INPUTS       #
#=============================#
if [[ -z "$script_path" ]]; then
    echo "Error: No script path provided."
    show_help
    exit 1
fi

if [[ ! -f "$script_path" ]]; then
    echo "Error: File '$script_path' does not exist."
    exit 1
fi

#=============================#
#       SETUP VARIABLES      #
#=============================#
script_name=$(basename "$script_path")
date_str=$(date +%F)
time_str=$(date +%H-%M-%S)
backup_dir="$HOME/.logs/scripts/$date_str/$time_str"
backup_path="$backup_dir/${script_name}.bak"

# Use user-specified editor, else fall back to \$EDITOR or 'nano'
chosen_editor="${editor:-${EDITOR:-nano}}"

#=============================#
#       CHECK EDITOR         #
#=============================#
if ! command -v "$chosen_editor" >/dev/null 2>&1; then
    echo "Editor '$chosen_editor' not found in PATH."
    echo "Please use an editor that is installed and accessible via the PATH."
    exit 1
fi

#=============================#
#       BACKUP SCRIPT        #
#=============================#
mkdir -p "$backup_dir"
cp --preserve=mode,timestamps "$script_path" "$backup_path"

#=============================#
#      EMPTY ORIGINAL FILE   #
#=============================#
: > "$script_path"

#=============================#
#      OPEN IN EDITOR        #
#=============================#
"$chosen_editor" "$script_path"

