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

if [[ "$file_type" != "" && "$file_type" != "sh" && "$file_type" != "py" ]]; then
    echo "Error: Unsupported file type '$file_type'. Supported types are 'sh' and 'py'."
    exit 1
fi

if [[ "$mode" != "full" && "$mode" != "filename" && "$mode" != "relative" ]]; then
    echo "Error: Unsupported mode '$mode'. Supported modes are 'full', 'filename', and 'relative'."
    exit 1
fi

# Find all files in the directory and store them in an array
files=()
if [[ -n "$file_type" ]]; then
    while IFS= read -r -d $'\0' file; do
        files+=("$file")
    done < <(find "$directory" -type f -name "*.$file_type" -print0)
else
    while IFS= read -r -d $'\0' file; do
        files+=("$file")
    done < <(find "$directory" -type f -print0)
fi

# Print the array elements based on the chosen mode
for file in "${files[@]}"; do
    case $mode in
        full)
            echo "$file"
            ;;
        filename)
            echo "$(basename "$file")"
            ;;
        relative)
            echo "${file#"$directory"/}"
            ;;
    esac
done

