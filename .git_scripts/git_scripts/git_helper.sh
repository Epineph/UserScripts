#!/bin/bash

# Function to display help/usage
show_help() {
  cat << EOF
Usage: git_helper [OPTIONS]

Options:
  -e, --edited     List and view files currently being edited (staged or modified).
  -t, --tracked    List all currently tracked files in the repository.
  -d, --diff       Show differences between edited and tracked files.
  -h, --help       Display this help message and exit.

Description:
  This script enhances your Git workflow by using tools like fd, bat, and fzf to make it easier to track, view, and compare files in your repository.

Examples:
  List and view edited files:
    git_helper -e

  List all tracked files:
    git_helper -t

  Show differences in edited and tracked files:
    git_helper -d

EOF
}

# Function to list and view files currently being edited (staged or modified)
list_edited_files() {
  echo "Searching for edited files..."
  edited_files=$(git status --porcelain | grep -E '^(M|A|R)' | awk '{print $2}')
  
  if [ -z "$edited_files" ]; then
    echo "No edited files found."
    exit 0
  fi

  echo "$edited_files" | fzf --multi --preview="bat --paging=never --style=numbers --color=always --line-range :500 {}" --height=40% --border --header="Select files to view"

  if [ $? -ne 0 ]; then
    echo "No files selected."
  fi
}

# Function to list all tracked files in the repository
list_tracked_files() {
  echo "Listing all tracked files..."
  tracked_files=$(git ls-files)

  if [ -z "$tracked_files" ]; then
    echo "No tracked files found."
    exit 0
  fi

  echo "$tracked_files" | fzf --multi --preview="bat --paging=never --style=numbers --color=always --line-range :500 {}" --height=40% --border --header="Select files to view"
  
  if [ $? -ne 0 ]; then
    echo "No files selected."
  fi
}

# Function to show differences between edited and tracked files
show_diff_files() {
  echo "Searching for edited files..."
  edited_files=$(git status --porcelain | grep -E '^(M|A|R)' | awk '{print $2}')
  
  if [ -z "$edited_files" ]; then
    echo "No edited files found."
    exit 0
  fi

  selected_file=$(echo "$edited_files" | fzf --multi --preview="git diff --color=always {} | bat --paging=never --language=diff --style=numbers" --height=40% --border --header="Select files to view diff")

  if [ -n "$selected_file" ]; then
    echo "Diff for $selected_file:"
    git diff --color=always "$selected_file" | bat --paging=never --language=diff --style=numbers
  else
    echo "No files selected."
  fi
}

# Parse arguments
case "$1" in
  -e|--edited)
    list_edited_files
    ;;
  -t|--tracked)
    list_tracked_files
    ;;
  -d|--diff)
    show_diff_files
    ;;
  -h|--help)
    show_help
    ;;
  *)
    echo "Invalid option: $1"
    show_help
    exit 1
    ;;
esac

