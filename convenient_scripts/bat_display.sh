#!/bin/bash

# Help Section
function display_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [DIRECTORY]

This script uses 'bat' to display the contents of files in a given directory.
If no directory is provided, the current directory is used.

Options:
  -r, -R, --recurse, --Recurse          Recursively search through the directory.
  -t, --tree LEVEL                     Specify the number of levels to search down (default: 1 if --recurse is not used).
  -e, -E, --extension, --Extension     Specify file extensions to display (e.g., "sh,py,md").
  -s, --style STYLE                    Specify the 'bat' style (default: grid).
  -T, --theme THEME                    Specify the 'bat' theme (default: Dracula).
  -h, --help                           Display this help message.

Examples:
  Display shell, Python, and Markdown files in a given path recursively:
    $(basename "$0") -e "sh,py,md" -r /some/path

  Display shell and Markdown files with a plain style and 'TwoDark' theme:
    $(basename "$0") -e "sh,md" --style=plain --theme=TwoDark

  Display shell and Markdown files 3 levels deep from the specified path:
    $(basename "$0") -t 3 -e "sh,md" /some/path
EOF
}

# Default Parameters
RECURSE=false
FREE_LEVEL=1
EXTENSIONS="sh,py,md"
STYLE="grid"
THEME="Dracula"
DIRECTORY="$(pwd)"

# Function to configure bat settings
function bat_configs() {
    local default_bat_style="grid"
    local default_bat_theme="Dracula"
    local default_bat_pager="never"

    local current_bat_style="${1:-$default_bat_style}"
    local current_bat_theme="${2:-$default_bat_theme}"
    local current_bat_pager="${3:-$default_bat_pager}"

    echo "--style=$current_bat_style --theme=$current_bat_theme --paging=$current_bat_pager"
}

# Parse Arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -r|-R|--recurse|--Recurse)
            RECURSE=true
            shift
            ;;
        -t|--tree)
            FREE_LEVEL="$2"
            shift 2
            ;;
        -e|-E|--extension|--Extension)
            EXTENSIONS="$2"
            shift 2
            ;;
        -s|--style)
            STYLE="$2"
            shift 2
            ;;
        -T|--theme)
            THEME="$2"
            shift 2
            ;;
        -h|--help)
            display_help
            exit 0
            ;;
        *)
            DIRECTORY="$1"
            shift
            ;;
    esac
done

# Convert EXTENSIONS to an array
IFS=',' read -r -a FILE_TYPES <<< "$EXTENSIONS"

# Build find command
FIND_CMD=("find" "$DIRECTORY")
if [ "$RECURSE" = true ]; then
    FIND_CMD+=("-maxdepth" "$FREE_LEVEL")
else
    FIND_CMD+=("-maxdepth" "1")
fi

# Add file type filters to find command
TYPE_FILTER=()
for TYPE in "${FILE_TYPES[@]}"; do
    TYPE_FILTER+=("-name" "*.$TYPE" "-o")
done
# Remove the last "-o" from the filter
unset 'TYPE_FILTER[-1]'

FIND_CMD+=("(" "${TYPE_FILTER[@]}" ")")

# Execute find command and use bat to display files
BAT_OPTIONS=$(bat_configs "$STYLE" "$THEME")
${FIND_CMD[@]} | while read -r FILE; do
    if [ -f "$FILE" ]; then
        bat $BAT_OPTIONS "$FILE"
    fi
done
