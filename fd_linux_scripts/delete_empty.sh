#!/bin/bash
# delete_empty.sh - Find and delete empty files and directories

cat <<EOF
Usage: delete_empty.sh

Description:
  This script finds empty files and directories and allows you to delete selected ones interactively using 'fzf'.

Examples:
  delete_empty.sh
EOF

# Find empty files and directories
empty_items=$(fd --type empty)

if [ -z "$empty_items" ]; then
    echo "No empty files or directories found."
    exit 0
fi

# Preview empty items with fzf and delete selected ones
echo "$empty_items" | fzf --multi --preview 'bat --style=numbers --color=always --line-range :500 {}' --height 40% --layout=reverse --border | xargs -r rm -r

