#!/bin/bash

# A function to display available commands
function show_help() {
  cat << EORF
Available commands:
  init                - Initialize a new git repository
  clone <url>         - Clone a git repository from URL
  status              - Show the working tree status
  branch              - List, create, or delete branches
  checkout            - Switch branches or restore working tree files
  new-branch <name>   - Create a new branch and switch to it
  merge <branch>      - Merge the specified branch into the current branch
  log                 - Show commit logs
  diff                - Show changes between commits, commit and working tree, etc
  upload <message>    - Add, commit, and push changes with a commit message
  help                - Show this help message
EORF
}

# Function to initialize a new git repository
function init_repo() {
  git init
}

# Function to clone a git repository
function clone_repo() {
  local url="$1"
  if [[ -z "$url" ]]; then
    echo "Error: Repository URL is required for cloning."
    exit 1
  fi
  git clone "$url"
}

# Function to show the working tree status
function show_status() {
  git status
}

# Function to list, create, or delete branches
function manage_branches() {
  local branch
  branch=$(git branch | fzf)
  git checkout "$branch"
}

# Function to switch branches or restore working tree files
function checkout_branch() {
  local branch
  branch=$(git branch | fzf)
  git checkout "$branch"
}

# Function to create a new branch and switch to it
function create_new_branch() {
  local branch_name="$1"
  if [[ -z "$branch_name" ]]; then
    read -p "Enter new branch name: " branch_name
  fi
  git checkout -b "$branch_name"
}

# Function to merge branches
function merge_branch() {
  local branch="$1"
  if [[ -z "$branch" ]]; then
    branch=$(git branch | fzf)
  fi
  git merge "$branch"
}

# Function to show commit logs
function show_log() {
  git log | sudo "$(which bat)" --style=grid
}

# Function to show changes between commits, commit and working tree, etc
function show_diff() {
  git diff | sudo "$(which bat)" --style=grid
}

# Function to add, commit, and push changes
function upload_changes() {
  local message="$1"
  if [[ -z "$message" ]]; then
    read -p "Enter commit message: " message
  fi
  git add .
  git commit -m "$message"
  git push
}

# Main script logic
if [[ $# -eq 0 ]]; then
  command=$(printf "init\nclone\nstatus\nbranch\ncheckout\nnew-branch\nmerge\nlog\ndiff\nupload\nhelp" | fzf)
else
  command="$1"
  shift
fi

case "$command" in
  init)
    init_repo
    ;;
  clone)
    clone_repo "$@"
    ;;
  status)
    show_status
    ;;
  branch)
    manage_branches
    ;;
  checkout)
    checkout_branch
    ;;
  new-branch)
    create_new_branch "$@"
    ;;
  merge)
    merge_branch "$@"
    ;;
  log)
    show_log
    ;;
  diff)
    show_diff
    ;;
  upload)
    upload_changes "$@"
    ;;
  help)
    show_help
    ;;
  *)
    echo "Error: Unknown command '$command'"
    show_help
    exit 1
    ;;
esac

