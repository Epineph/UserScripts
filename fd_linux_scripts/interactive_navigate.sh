#!/bin/bash
# interactive_navigate.sh - Interactive directory navigation

cat <<EOF
Usage: interactive_navigate.sh

Description:
  This script finds directories and allows you to navigate to the selected one interactively using 'fzf'.

Examples:
  interactive_navigate.sh
EOF

# Find directories and navigate to the selected one
selected_dir=$(fd --type d . | fzf --height 40% --layout=reverse --border)
if [ -n "$selected_dir" ]; then
    cd "$selected_dir" || exit
    exec bash
fi

