#!/bin/bash

# Function to display usage
show_help() {
    cat << EOF
Usage: $(basename "$0") [-n|--name <repo_name>] [-d|--directory <repo_directory>] [-e|--description <description_text_or_file_path>] [-s|--setup-local-gh]

Arguments
  -n|--name             The name of the repository.
  -d|--directory        The directory to initialize or use for the repository. Defaults to the current directory.   
  -e|--description      A description for the repository or a path to a file containing the description. Optional.
  -s|--setup-local-gh   Flag to setup a new GitHub repository. Without this, assumes managing an existing repository.
EOF
}


# Default values
REPO_NAME=""
REPO_DIR=""
REPO_DESC=""
SETUP_GH=false

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -n|--name) REPO_NAME="$2"; shift ;;
        -d|--directory) REPO_DIR="$2"; shift ;;
        -e|--description) REPO_DESC="$2"; shift ;;
        -s|--setup-local-gh) SETUP_GH=true ;;
        *) usage ;;
    esac
    shift
done

# Check for setup flag without necessary arguments
if $SETUP_GH && [ -z "$REPO_NAME" ]; then
    echo "Repository name is required for setup."
    usage
fi

# Use current directory if no directory provided
if [ -z "$REPO_DIR" ]; then
    read -p "No directory specified. Use current directory? (y/n) " yn
    case $yn in
        [Yy]* ) REPO_DIR=$(pwd);;
        [Nn]* ) echo "Exiting. Please specify a directory."; exit 1;;
        * ) echo "Please answer yes or no."; exit 1;;
    esac
fi

# Validate or create directory
if [ ! -d "$REPO_DIR" ]; then
    read -p "Directory does not exist. Create it? (y/n) " yn
    case $yn in
        [Yy]* ) mkdir -p "$REPO_DIR";;
        [Nn]* ) echo "Exiting. Please specify an existing directory."; exit 1;;
        * ) echo "Please answer yes or no."; exit 1;;
    esac
fi

# Further implementation based on the flags and arguments provided
# This is where you'd handle repo initialization, adding files, committing, etc.

echo "Repository Name: $REPO_NAME"
echo "Repository Directory: $REPO_DIR"
echo "Repository Description: $REPO_DESC"
echo "Setup GitHub Repository: $SETUP_GH"

