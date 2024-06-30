#!/bin/bash

# Generate a new GPG key
echo "Generating a new GPG key..."
gpg --full-generate-key

# List secret keys and get the GPG key ID
echo "Listing your GPG keys..."
gpg --list-secret-keys --keyid-format=long

# Prompt user to enter the GPG key ID
echo "Enter the GPG key ID (long form) you'd like to use for signing commits:"
read -r GPG_KEY_ID

# Configure Git to use the GPG key for signing commits
git config --global user.signingkey "$GPG_KEY_ID"

# Ask if the user wants to sign all commits by default
echo "Would you like to sign all commits by default? (y/n)"
read -r SIGN_ALL_COMMITS

if [ "$SIGN_ALL_COMMITS" = "y" ]; then
  git config --global commit.gpgsign true
fi

# Add GPG_TTY to .bashrc (or .zshrc if using zsh)
#if [ -f ~/.bashrc ]; then
#  echo -e '\nexport GPG_TTY=$(tty)' >> ~/.bashrc
#  source ~/.bashrc
#elif [ -f ~/.zshrc ]; then
#  echo -e '\nexport GPG_TTY=$(tty)' >> ~/.zshrc
#  source ~/.zshrc
#fi

echo "GPG key generated and Git configured to use it for signing commits."

# Generate a new SSH key
echo "Generating a new SSH key..."
ssh-keygen -t ed25519 -C "$(git config user.email)"

# Start the SSH agent
echo "Starting the SSH agent..."
eval "$(ssh-agent -s)"

# Add the SSH private key to the SSH agent
ssh-add ~/.ssh/id_ed25519

# Display the SSH public key
echo "Here is your SSH public key:"
cat ~/.ssh/id_ed25519.pub

# Provide instructions to add the SSH key to GitHub
echo "To add the SSH key to GitHub, follow these steps:"
echo "1. Copy the SSH key above."
echo "2. Go to GitHub and navigate to Settings > SSH and GPG keys > New SSH key."
echo "3. Paste the SSH key and give it a title."

# Output the GPG key in the format needed for GitHub
echo "Here is your GPG key in the format needed for GitHub:"
gpg --armor --export "$GPG_KEY_ID"

