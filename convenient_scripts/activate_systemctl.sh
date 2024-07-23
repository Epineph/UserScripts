#!/bin/bash

# Function to enable selected services
enable_services() {
    while IFS= read -r service; do
        echo "Enabling ${service}..."
        sudo systemctl enable "$service"
        sudo systemctl start "$service"
    done
}

export -f enable_services

# Main command
fd .service$ /etc/systemd/system/ | fzf --multi --preview 'bat --color=always --style=grid --line-range :500 {}' --preview-window=down:70%:wrap --bind 'tab:toggle+down' --bind 'shift-tab:toggle+up' --bind 'enter:execute(echo {} | xargs -n 1 basename | enable_services)+abort' | xargs -n 1 basename | enable_services

