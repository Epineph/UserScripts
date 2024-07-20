#!/bin/bash

COMMAND="${1:-conda}"
MINICONDA3_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
MINICONDA_PATH="$HOME/miniconda3"
echo "$SHELL"

sudo pacman -S wget curl --needed

command_exists() {
	command -v "$COMMAND" >/dev/null 2>&1
}

required_packages=("neovim" "git" "curl" "virtualenvwrapper" "conda")

missing_packages=()
for pkg in "${required_packages[@]}"; do
    if ! type "$pkg" > /dev/null 2>&1; then
	   if command_exists; then
		   read -r -p "install conda? (y/n)" prompt
	   fi

        missing_packages+=("$pkg")
    fi
done

if [[ "$prompt" == "y" ]]; then
  if [[ -d "$HOME/miniconda3" ]]; then
    echo "Error: path $HOME/miniconda3 not found"
    echo "Creating it..."
    sleep 1
    sudo mkdir -p $HOME/miniconda3
    wget "$MINICONDA3_URL" -O "$MINICONDA_PATH/miniconda.sh"
    bash "$HOME/miniconda3/miniconda.sh" -b -u -p "$MINICONDA_PATH"
    rm -rf ~/miniconda3/miniconda.sh
  fi

