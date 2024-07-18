#!/bin/bash
# fd_find_edit.sh - Find, preview, and edit files

cat <<EOF
Usage: fd_find_edit.sh [pattern]

Description:
  This script searches for files matching the specified pattern, previews them using 'bat',
  and allows you to select a file to edit using 'fzf' and 'nano'.

Arguments:
  pattern    The search pattern for files (supports wildcards).

Examples:
  fd_find_edit.sh '*.txt'
  fd_find_edit.sh 'myfile*'
EOF

# Search for files matching the pattern provided as the first argument
fd -e txt -e md "$1" | fzf --preview 'bat --style=numbers --color=always --line-range :500 {}' --height 40% --layout=reverse --border | xargs -r nano

