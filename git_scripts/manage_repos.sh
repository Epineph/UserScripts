#!/bin/bash

# Define the directory containing the repositories
REPOS_DIR="$HOME/repos"

# Define available editors and display commands
EDITORS=("vim" "nvim" "nano" "code")
DISPLAY_CMDS=("cat" "bat")

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
  if [ -f ~/.bashrc ]; then
    echo -e "\nexport GPG_TTY=$(tty)" >> ~/.bashrc
    source ~/.bashrc
  elif [ -f ~/.zshrc ]; then
    echo -e "\nexport GPG_TTY=$(tty)" >> ~/.zshrc
    source ~/.zshrc
  fi
  echo "GPG key generated and Git configured to use it for signing commits."
  echo "Your GPG public key to add to GitHub:"
  gpg --armor --export "$GPG_KEY_ID"
  echo "export GPG_TTY=$(tty)" | sudo tee -a "$HOME/.zshrc"
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

# Function to list branches and switch to a selected branch
git_change_branch() {
  local branches
  branches=$(git branch -a | fzf --prompt "Select branch to switch to:")
  if [ -n "$branches" ]; then
    git checkout "$branches"
  fi
}

# Function to commit and push changes to GitHub
git_commit_and_push() {
  local commit_message
  local repo_url
  local sanitized_url

  if [ -z "$GITHUB_TOKEN" ]; then
    echo "Error: GITHUB_TOKEN is not set in your environment."
    return 1
  fi

  echo "Enter the commit message:"
  read -r commit_message

  # Add all changes to the repository
  git add .

  # Commit the changes with the provided message
  git commit -S -m "$commit_message"

  # Get the repository URL and sanitize it
  repo_url=$(git config --get remote.origin.url)
  sanitized_url=$(echo "$repo_url" | sed 's|https://|https://'"$GITHUB_TOKEN"'@|')

  # Push the changes using the personal access token for authentication
  git push "$sanitized_url" main

  echo "Changes committed and pushed successfully."
}

# Function to update the repository
update_repo() {
  local repo=$1
  cd "$repo" || return

  echo "Updating repository: $repo"
  while true; do
    select action in "Pull changes" "Commit and push changes" "Change branch" "Quit"; do
      case $action in
        "Pull changes")
          git pull
          break
          ;;
        "Commit and push changes")
          git_commit_and_push
          break
          ;;
        "Change branch")
          git_change_branch
          break
          ;;
        "Quit")
          return
          ;;
      esac
    done
  done

  cd - || return
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
      update)
        ACTION="update"
        break
        ;;
      quit)
        exit 0
        ;;
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
select_action

# Prompt for selecting repositories using FZF
selected_repos=($(select_repos))

# Iterate over each selected repository and select files within each
for repo in "${selected_repos[@]}"; do
  if [ "$ACTION" == "edit" ] || [ "$ACTION" == "display" ]; then
    selected_files=($(select_files_in_repo "$repo"))
    perform_action "$ACTION" "$CMD" "${selected_files[@]}"
  elif [ "$ACTION" == "update" ]; then
    update_repo "$repo"
  fi
done

