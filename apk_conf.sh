#!/bin/bash

# Update and upgrade the system
apk update && apk upgrade

# Essential packages
essential_packages=(
    "apk-tools"
    "bash"
    "nano"
    "curl"
    "wget"
    "git"
    "openssh-client"
    "build-base"
    "sudo"
    "vim"
    "zsh"
    "python3"
    "htop"
    "tmux"
    "ncdu"
    "tree"
    "man-pages"
)

# Install packages
for pkg in "${essential_packages[@]}"; do
    if ! apk info -e "$pkg"; then
        apk add "$pkg"
    else
        echo "$pkg is already installed."
    fi
done

# Set up zsh as default shell
if [ "$(echo $SHELL)" != "/bin/zsh" ]; then
    chsh -s /bin/zsh
fi

# Configure git
git config --global user.name "Your Name"
git config --global user.email "youremail@example.com"

# Enable sudo for current user (replace 'yourusername' with actual username)
echo "yourusername ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Create a basic .zshrc configuration
cat <<EOF > ~/.zshrc
# Load oh-my-zsh if installed
if [ -f ~/.oh-my-zsh/oh-my-zsh.sh ]; then
  source ~/.oh-my-zsh/oh-my-zsh.sh
fi

# Aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# Enable syntax highlighting if installed
if [ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]; then
  source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
fi

# Prompt
PROMPT='%n@%m %1~ %# '
EOF

# Done
echo "Setup is complete! Please restart your shell."