#!/bin/bash
# convert_md_to_html.sh - Convert Markdown files to HTML

cat <<EOF
Usage: convert_md_to_html.sh

Description:
  This script finds all Markdown files (.md) in the current directory and converts them to HTML using 'pandoc'.

Examples:
  convert_md_to_html.sh
EOF

# Find Markdown files and convert them to HTML
fd -e md -0 | xargs -0 -I{} pandoc {} -o {}.html

