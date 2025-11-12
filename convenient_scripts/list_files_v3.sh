#!/bin/bash

# Function to display usage
show_help() {
    cat << EOF
Usage: $0 [-t|--type {sh|py}] [-m|--mode {full|filename|relative}] directory

Options:
  -t, --type      Filter files by type (sh or py)
  -m, --mode      Display mode: full (default), filename, or relative
  -h, --help      Show this help message

Examples:
  $0 /path/to/directory
  $0 -t sh /path/to/directory
  $0 -m filename /path/to/directory
  $0 -t py -m relative /path/to/directory
EOF
}

# Parse arguments
file_type=""
mode="full"
directory=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -t|--type)
            file_type="$2"
            shift 2
            ;;
        -m|--mode)
            mode="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            directory="$1"
            shift
            ;;
    esac
done

# Validate arguments
if [[ -z "$directory" ]]; then
    show_help
    exit 1
fi

if [[ ! -d "$directory" ]]; then
    echo "Error: '$directory' is not a directory"
    exit 1
fi

if [[ "$file_type" != "" && "$file_type" != "sh" && "$file_type" != "py" && "$file_type" != "ps1" ]]; then
    echo "Error: Unsupported file type '$file_type'. Supported types are 'sh', 'ps1' and 'py'."
    exit 1
fi

if [[ "$mode" != "full" && "$mode" != "filename" && "$mode" != "relative" && "$mode" != "reveal" ]]; then
    echo "Error: Unsupported mode '$mode'. Supported modes are 'full', 'filename', and 'relative'."
    exit 1
fi

# Find files using fd
if [[ -n "$file_type" ]]; then
    files=$(fd -e "$file_type" . "$directory")
else
    files=$(fd . "$directory")
fi

# Display files based on the chosen mode
for file in $files; do
    case $mode in
        full)
            exa -la --recurse -L=1 --tree --group-directories-first --long --header --group --time-style=long-iso "$file"
            ;;
        filename)
            echo "$(basename "$file")"
            ;;
        relative)
            echo "${file#"$directory"/}"
            ;;
        reveal)
            (cd "$directory" && sudo "$(which bat)" --style=grid --paging=never --color=always --theme=Dracula "${file#"$directory"/}")
    esac
done

