#!/bin/bash

# Function to display usage
usage() {
    echo "Usage: $0 [-t|--type {sh|py}] directory"
    exit 1
}

# Parse arguments
file_type=""
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -t|--type)
            file_type="$2"
            shift 2
            ;;
        *)
            directory="$1"
            shift
            ;;
    esac
done

# Validate arguments
if [[ -z "$directory" ]]; then
    usage
fi

if [[ ! -d "$directory" ]]; then
    echo "Error: '$directory' is not a directory"
    exit 1
fi

if [[ "$file_type" != "" && "$file_type" != "sh" && "$file_type" != "py" ]]; then
    echo "Error: Unsupported file type '$file_type'. Supported types are 'sh' and 'py'."
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



# Print the array elements
for file in "${files[@]}"; do
    echo "$file"
done

