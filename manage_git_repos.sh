#!/bin/bash

# Variables
REPOS_DIR="$HOME/repos"
EDITORS=("vim" "nvim" "nano" "code")
DISPLAY_CMDS=("cat" "bat")
GPG_TTY_EXPORT="export GPG_TTY=$(tty)"
GPG_FILE="$HOME/.zshrc"
SSH_KEY="$HOME/.ssh/id_rsa"

# Function to check for and install required packages
install_pkgs() {
    local needed_pkgs=("github-cli" "openssh" "git")
    local missing_pkgs=()
    for pkg in "${needed_pkgs[@]}"; do
        if ! pacman -Qi "$pkg" &> /dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done
    if [ ${#missing_pkgs[@]} -ne 0 ]; then
        echo "The following packages are not installed: ${missing_pkgs[*]}"
        read -p "Do you want to install them? (Y/n) " -n 1 -r
        echo    # Move to a new line
        if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
            for package in "${missing_pkgs[@]}"; do
                yes | sudo pacman -S "$package"
                if [ $? -ne 0 ]; then
                    echo "Failed to install $package. Aborting."
                    exit 1
                fi
            done
        else
            echo "The following packages are required to continue: ${missing_pkgs[*]}. Aborting."
            exit 1
        fi
    fi
}

# Function to generate a GPG key
generate_gpg_key() {
    echo "Generating a new GPG key..."
    gpg --full-generate-key
    echo "Listing your GPG keys..."
    gpg --list-secret-keys --keyid-format=long
    echo "Enter the GPG key ID (long form) you'd like to use for signing commits:"
    read -r GPG_KEY_ID
    echo "Configuring Git to use the GPG key..."
    git config --global user.signingkey "$GPG_KEY_ID"
    echo "Would you like to sign all commits by default? (y/n)"
    read -r SIGN_ALL_COMMITS
    if [ "$SIGN_ALL_COMMITS" = "y" ]; then
        git config --global commit.gpgsign true
    fi
    echo -e "\n$GPG_TTY_EXPORT" | sudo tee -a "$GPG_FILE"
    source "$GPG_FILE"
    echo "GPG key generated and Git configured to use it for signing commits."
    echo "Your GPG public key to add to GitHub:"
    gpg --armor --export "$GPG_KEY_ID"
}

# Function to generate an SSH key
generate_ssh_key() {
    echo "Generating a new SSH key..."
    ssh-keygen -t rsa -b 4096 -C "$(git config user.email)"
    echo "Starting the ssh-agent..."
    eval "$(ssh-agent -s)"
    echo "Adding your SSH key to the ssh-agent..."
    ssh-add ~/.ssh/id_rsa
    echo "Your SSH public key to add to GitHub:"
    cat ~/.ssh/id_rsa.pub
}

# Function to initialize a Git repository
initialize_git_repo() {
    echo "Would you like to use the current directory ($(pwd)) for the new Git repo? (y/n)"
    read -r use_current_dir
    if [ "$use_current_dir" = "y" ]; then
        REPO_DIR=$(pwd)
    else
        echo "Enter the directory for the new Git repo:"
        read -r REPO_DIR
    fi
    cd "$REPO_DIR" || exit
    git init
    git add .
    git commit -m "Initial commit"
    echo "Repository initialized."
}

# Function to create a GitHub repository and push to it
create_and_push_github_repo() {
    echo "Enter the name of the GitHub repository:"
    read -r REPO_NAME
    gh repo create "$REPO_NAME" --public --source=. --remote=origin
    git push -u origin master
    echo "Repository '$REPO_NAME' created and files uploaded successfully."
}

# Function to commit and push changes to GitHub
git_commit_and_push() {
    local commit_message
    echo "Enter the commit message:"
    read -r commit_message
    git add .
    git commit -S -m "$commit_message"
    git push origin main
    echo "Changes committed and pushed successfully."
}

# Function to pull changes from the repository
git_pull_changes() {
    git pull
    echo "Changes pulled from the repository."
}

# Function to switch branches
git_change_branch() {
    local branches
    branches=$(git branch -a | fzf --prompt "Select branch to switch to:")
    if [ -n "$branches" ]; then
        git checkout "$branches"
    fi
}

# Function to update the repository
update_repo() {
    echo "Updating repository: $(pwd)"
    select action in "Pull changes" "Commit and push changes" "Change branch" "Quit"; do
        case $action in
            "Pull changes") git_pull_changes ;;
            "Commit and push changes") git_commit_and_push ;;
            "Change branch") git_change_branch ;;
            "Quit") return ;;
        esac
    done
}

# Function to select an editor or display command
select_action() {
    echo "Do you want to edit, display, or update a repository?"
    select action in "edit" "display" "update" "quit"; do
        case $action in
            edit)
                echo "Select an editor:"
                select editor in "${EDITORS[@]}"; do
                    [ -n "$editor" ] && echo "Using editor: $editor" && break
                done
                ACTION=$action
                CMD=$editor
                break
                ;;
            display)
                echo "Select a display command:"
                select display_cmd in "${DISPLAY_CMDS[@]}"; do
                    [ -n "$display_cmd" ] && echo "Using display command: $display_cmd" && break
                done
                ACTION=$action
                CMD=$display_cmd
                break
                ;;
            update) ACTION="update" break ;;
            quit) exit 0 ;;
        esac
    done
}

# Function to select repositories using FZF
select_repos() {
    local repos=()
    while true; do
        repo=$(find "$REPOS_DIR" -mindepth 1 -maxdepth 1 -type d | fzf --multi --prompt "Select repositories (press Enter to proceed, Ctrl+C to finish):")
        [ -z "$repo" ] && break
        repos+=("$repo")
    done
    echo "${repos[@]}"
}

# Function to select files within a repository using FZF
select_files_in_repo() {
    local repo=$1
    local files=()
    while true; do
        file=$(find "$repo" -type f | fzf --multi --prompt "Select files in $repo (press Enter to proceed, Ctrl+C to finish):" --preview "bat --style=grid --color=always {}" --preview-window=right:60%:wrap)
        [ -z "$file" ] && break
        files+=("$file")
    done
    echo "${files[@]}"
}

# Function to perform actions on the selected files
perform_action() {
    local action=$1
    local cmd=$2
    shift 2
    local files=("$@")
    for file in "${files[@]}"; do
        if [[ $action == "edit" ]]; then
            $cmd "$file"
        elif [[ $action == "display" ]]; then
            $cmd "$file"
        fi
    done
}

# Main script execution
install_pkgs
select_action

# Prompt for selecting repositories using FZF
selected_repos=($(select_repos))

# Iterate over each selected repository and select files within each
for repo in "${selected_repos[@]}"; do
    cd "$repo" || continue
    if [ "$ACTION" == "edit" ] || [ "$ACTION" == "display" ]; then
        selected_files=($(select_files_in_repo "$repo"))
        perform_action "$ACTION" "$CMD" "${selected_files[@]}"
    elif [ "$ACTION" == "update" ]; then
        update_repo
    fi
done

