#!/bin/bash

# Initialize variables
FILE_PATH=""
DESCRIPTION=""
SCRIPT_NAME=""

# Function to display usage instructions
show_help() {
    cat << EOF
Usage: $0 -f|--file-path <file_path> -d|--description <description> -n|--name|--name-gist <name_on_gist>

Options:
  -f, --file-path       Path to the file to be uploaded as a gist.
  -d, --description     Description of the gist.
  -n, --name, --name-gist  Name for the gist file.
EOF
    exit 1
}

# Parse command line arguments
while [[ "$1" != "" ]]; do
    case $1 in
        -f | --file-path )    shift
                              FILE_PATH=$1
                              ;;
        -d | --description )  shift
                              DESCRIPTION=$1
                              ;;
        -n | --name | --name-gist ) shift
                                    SCRIPT_NAME=$1
                                    ;;
        * )                   show_help
    esac
    shift
done

# Check if all required arguments are provided
if [[ -z "$FILE_PATH" || -z "$DESCRIPTION" || -z "$SCRIPT_NAME" ]]; then
    show_help
fi

# Create the gist
gh gist create -p "$FILE_PATH" -d "$DESCRIPTION" -w -f "$SCRIPT_NAME"

