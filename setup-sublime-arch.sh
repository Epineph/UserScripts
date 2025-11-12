#!/usr/bin/env bash
#
# setup-sublime-arch.sh — Automate Sublime Text configuration on Arch Linux with popular packages and tweaks
# Usage: ./setup-sublime-arch.sh [--backup]
#
set -euo pipefail

# Default XDG_CONFIG_HOME if not set
: "${XDG_CONFIG_HOME:=${HOME}/.config}"

# Sublime Text config paths for Text 4
CONFIG_USER_DIR="$XDG_CONFIG_HOME/sublime-text/Packages/User"
INSTALLED_PKGS_DIR="$XDG_CONFIG_HOME/sublime-text/Installed Packages"
# Legacy Sublime Text 3 paths
LEGACY_USER_DIR="$HOME/.config/sublime-text-3/Packages/User"
LEGACY_INSTALLED_DIR="$HOME/.config/sublime-text-3/Installed Packages"

# Use legacy paths if Sublime Text 3 exists but Text 4 config dir does not
if [[ -d "$LEGACY_USER_DIR" && ! -d "$CONFIG_USER_DIR" ]]; then
  CONFIG_USER_DIR="$LEGACY_USER_DIR"
  INSTALLED_PKGS_DIR="$LEGACY_INSTALLED_DIR"
fi

# Backup flag and timestamp
BACKUP=false
TS=$(date +%Y%m%d%H%M%S)

# Display help message
template_help() {
  cat << 'EOF'
setup-sublime-arch.sh — Automate Sublime Text configuration on Arch Linux

Usage:
  $0 [--backup]

Options:
  --backup    Backup existing Sublime Text config files before overwriting.

This script will:
  1. Backup existing Preferences, keymaps, and Package Control settings (if requested).
  2. Download and install Package Control.
  3. Generate core settings, keybindings, and package list configurations.
EOF
}

# Parse arguments
if [[ "${1:-}" == "--backup" ]]; then
  BACKUP=true
fi

# Show help if requested
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  template_help
  exit 0
fi

# Backup existing configs if requested
if $BACKUP; then
  echo "Backing up existing configs in: $CONFIG_USER_DIR"
  for file in "Preferences.sublime-settings" "Package Control.sublime-settings" "Default (Linux).sublime-keymap"; do
    if [[ -f "$CONFIG_USER_DIR/$file" ]]; then
      mv "$CONFIG_USER_DIR/$file" "$CONFIG_USER_DIR/${file}.bak-$TS"
      echo "  • $file → ${file}.bak-$TS"
    fi
  done
fi

# Ensure necessary directories exist
mkdir -p "$CONFIG_USER_DIR" "$INSTALLED_PKGS_DIR"

echo "Installing Package Control..."
# Use percent-encoded URL to avoid malformed-URL errors
curl -fsSL "https://packagecontrol.io/Package%20Control.sublime-package" \
     -o "$INSTALLED_PKGS_DIR/Package Control.sublime-package"

echo "Writing Package Control settings..."
cat > "$CONFIG_USER_DIR/Package Control.sublime-settings" << 'EOF'
{
  // List of packages to install via Package Control
  "installed_packages": [
    "Emmet",
    "SublimeLinter",
    "SublimeLinter-flake8",
    "SublimeLinter-eslint",
    "GitGutter",
    "SidebarEnhancements",
    "A File Icon",
    "Material Theme",
    "Dracula Color Scheme",
    "BracketHighlighter",
    "AutoFileName",
    "MarkdownPreview",
    "Terminus",
    "LSP",
    "LSP-pyright",
    "LSP-typescript",
    "DocBlockr",
    "GitSavvy",
    "AlignTab",
    "AllAutocomplete",
    "ColorHelper"
  ]
}
EOF

echo "Writing core Preferences..."
cat > "$CONFIG_USER_DIR/Preferences.sublime-settings" << 'EOF'
{
  // UI Theme and color scheme
  "theme": "Material-Theme.sublime-theme",
  "color_scheme": "Packages/Dracula Color Scheme/Dracula.tmTheme",

  // Editor font
  "font_face": "Fira Code",
  "font_size": 12,

  // Tabs and indentation
  "translate_tabs_to_spaces": true,
  "tab_size": 4,
  "detect_indentation": true,

  // Clean up whitespace on save
  "ensure_newline_at_eof_on_save": true,
  "trim_trailing_white_space_on_save": true,

  // Typing and wrap
  "auto_complete": true,
  "auto_complete_delay": 50,
  "highlight_line": true,
  "word_wrap": false,

  // Sidebar settings
  "sidebar_tree_indent": 2,

  // Disable Vintage mode if not needed
  "ignored_packages": ["Vintage"]
}
EOF

echo "Writing custom keybindings..."
cat > "$CONFIG_USER_DIR/Default (Linux).sublime-keymap" << 'EOF'
[
  // Quick save
  { "keys": ["ctrl+s"], "command": "save" },

  // Toggle side bar
  { "keys": ["ctrl+k", "ctrl+b"], "command": "toggle_side_bar" },

  // Open terminal panel (Terminus)
  { "keys": ["ctrl+`"], "command": "terminus_open" },

  // Wrap selection in double quotes
  { "keys": ["ctrl+shift+'"], "command": "insert_snippet", "args": { "contents": "\"$SELECTION\"" } }
]
EOF

echo "✅ Sublime Text configuration deployed to: $CONFIG_USER_DIR"
echo "➜ Launch Sublime Text, open Command Palette (Ctrl+Shift+P) → 'Package Control: Install Package' to install packages."

