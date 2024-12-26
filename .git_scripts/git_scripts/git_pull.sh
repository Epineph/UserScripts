#!/bin/bash

# Function to generate a GPG key

LINE_TO_ADD="export GPG_TTY=$(tty)"
FILE_TO_EDIT="$HOME/.zshrc"

# Check if the line is already in the file
if ! grep -qF "$LINE_TO_ADD" "$FILE_TO_EDIT"; then
  echo "$LINE_TO_ADD" | sudo tee -a "$FILE_TO_EDIT"
fi


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
  echo "export GPG_TTY=$(tty)" | sudo tee -a "$HOME/".zshrc
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

# Function to push changes to GitHub
git_push() {
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

# Main script logic
echo "Do you need to generate a GPG key? (y/n)"
read -r NEED_GPG
if [ "$NEED_GPG" = "y" ]; then
  generate_gpg_key
fi

echo "Do you need to generate an SSH key? (y/n)"
read -r NEED_SSH
if [ "$NEED_SSH" = "y" ]; then
  generate_ssh_key
fi

# Prompt for commit message and push changes
git_push

