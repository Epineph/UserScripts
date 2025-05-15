#!/usr/bin/env bash
#
# setup_sublime.sh — Automate Sublime Text configuration with popular packages and tweaks
# Usage: ./setup_sublime.sh [--backup]
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

# Use legacy paths if only Sublime Text 3 is present
if [[ -d "$LEGACY_USER_DIR" && ! -d "$CONFIG_USER_DIR" ]]; then
  CONFIG_USER_DIR="$LEGACY_USER_DIR"
  INSTALLED_PKGS_DIR="$LEGACY_INSTALLED_DIR"
fi

# Backup flag and timestamp
BACKUP=false
TS=$(date +%Y%m%d%H%M%S)

# Display help message
show_help() {
  cat << 'EOF'
setup_sublime.sh — Automate Sublime Text configuration

Usage:
  ./setup_sublime.sh [--backup]

Options:
  --backup    Backup existing Sublime Text config files before overwriting.

This script will:
  1. Optionally back up existing Preferences, keymaps, and Package Control settings.
  2. Download Package Control.
  3. Create or overwrite:
     - Preferences.sublime-settings (core settings).
     - Package Control.sublime-settings (list of packages).
     - Default (Linux).sublime-keymap (custom keys).
EOF
}

# Parse arguments
if [[ "${1:-}" == "--backup" ]]; then
  BACKUP=true
fi

# Backup existing configs if requested
if $BACKUP; then
  echo "Backing up existing configs..."
  for file in "Preferences.sublime-settings" "Package Control.sublime-settings" "Default (Linux).sublime-keymap"; do
    if [[ -f "$CONFIG_USER_DIR/$file" ]]; then
      mv "$CONFIG_USER_DIR/$file" "$CONFIG_USER_DIR/${file}.bak-$TS"
      echo "  • $file → ${file}.bak-$TS"
    fi
  done
fi

# Create necessary directories
mkdir -p "$CONFIG_USER_DIR" "$INSTALLED_PKGS_DIR"

# 1. Install Package Control
echo "Installing Package Control..."
curl -fsSL "https://packagecontrol.io/Package Control.sublime-package" -o "$INSTALLED_PKGS_DIR/Package Control.sublime-package"

# 2. Write Package Control settings
cat > "$CONFIG_USER_DIR/Package Control.sublime-settings" << 'EOF'
{
  // List of packages to install via Package Control
  "installed_packages":
  [
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

# 3. Write core Preferences
cat > "$CONFIG_USER_DIR/Preferences.sublime-settings" << 'EOF'
{
  // UI Theme settings
  "theme": "Material-Theme.sublime-theme",
  "color_scheme": "Packages/Dracula Color Scheme/Dracula.tmTheme",

  // Font settings
  "font_face": "Fira Code",
  "font_size": 12,

  // Indentation settings
  "translate_tabs_to_spaces": true,
  "tab_size": 4,
  "detect_indentation": true,

  // Save and trim
  "ensure_newline_at_eof_on_save": true,
  "trim_trailing_white_space_on_save": true,

  // UX tweaks
  "highlight_line": true,
  "word_wrap": false,
  "auto_complete": true,
  "auto_complete_delay": 50,

  // Sidebar
  "sidebar_tree_indent": 2,

  // Disable Vintage unless desired
  "ignored_packages": ["Vintage"]
}
EOF

# 4. Write custom keybindings
cat > "$CONFIG_USER_DIR/Default (Linux).sublime-keymap" << 'EOF'
[
  // Quick save
  { "keys": ["ctrl+s"], "command": "save" },

  // Toggle sidebar visibility
  { "keys": ["ctrl+k", "ctrl+b"], "command": "toggle_side_bar" },

  // Open Terminus terminal panel
  { "keys": ["ctrl+`"], "command": "terminus_open" },

  // Wrap selection with quotes
  { "keys": ["ctrl+shift+'"], "command": "insert_snippet", "args": { "contents": "\"$SELECTION\"" } }
]
EOF

# Final instructions
echo "✅ Sublime Text configuration deployed to $CONFIG_USER_DIR"
echo "➜ Launch Sublime Text, then open Command Palette (Ctrl+Shift+P) → 'Package Control: Install Package' to ensure packages install."
