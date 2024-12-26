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
if [ -f ~/.bashrc ]; then
  echo -e '\nexport GPG_TTY=$(tty)' >> ~/.bashrc
  source ~/.bashrc
elif [ -f ~/.zshrc ]; then
  echo -e '\nexport GPG_TTY=$(tty)' >> ~/.zshrc
  source ~/.zshrc
fi

echo "GPG key generated and Git configured to use it for signing commits."

