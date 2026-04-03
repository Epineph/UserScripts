#!/usr/bin/env bash
#
# setup-sublime-arch.sh — Automate Sublime Text configuration on Arch Linux
# with Language‑Server‑Protocol (LSP) clients, rich Bash workflow tooling,
# an extended palette of colour‑schemes / UI themes, and sensible defaults.
#
# Usage:
#   ./setup-sublime-arch.sh [--backup]
#
# Options:
#   --backup    Backup existing User settings before overwriting.
#   -h, --help  Show this help message.
#
# This script performs the following steps:
#   1. Optionally backs‑up existing *User* preferences, keymaps and plug‑in settings.
#   2. Bootstraps **Package Control** (if not yet present).
#   3. Installs a curated set of packages:  ➟ LSP clients   ➟ linters / formatters
#      ➟ Bash completions + diagnostics   ➟ UI/Icon packs   ➟ colour‑schemes.
#   4. Writes: *Preferences.sublime-settings*, *Package Control.sublime-settings*,
#      *LSP.sublime-settings* and platform key‑bindings.
#
# Author:  OpenAI ChatGPT — tweaked per user request (May 2025)
# Licence: MIT
# -----------------------------------------------------------------------------
set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration paths
# -----------------------------------------------------------------------------
: "${XDG_CONFIG_HOME:=${HOME}/.config}"
CONFIG_USER_DIR="$XDG_CONFIG_HOME/sublime-text/Packages/User"
INSTALLED_PKGS_DIR="$XDG_CONFIG_HOME/sublime-text/Installed Packages"
LEGACY_USER_DIR="$HOME/.config/sublime-text-3/Packages/User"
LEGACY_INSTALLED_DIR="$HOME/.config/sublime-text-3/Installed Packages"
if [[ -d "$LEGACY_USER_DIR" && ! -d "$CONFIG_USER_DIR" ]]; then
  CONFIG_USER_DIR="$LEGACY_USER_DIR"
  INSTALLED_PKGS_DIR="$LEGACY_INSTALLED_DIR"
fi

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
BACKUP=false
TS=$(date +%Y%m%d%H%M%S)
case "${1:-}" in
  --backup) BACKUP=true ;;
  -h|--help)
    cat << 'EOF'
setup-sublime-arch.sh — Automate Sublime Text configuration on Arch Linux

Usage:
  $0 [--backup]

Options:
  --backup    Backup existing Sublime Text User settings before overwriting.
  -h, --help  Show this help message.
EOF
    exit 0
    ;;
  "") : ;;  # allow running with no args
  *) echo "❌ Unknown option: $1" >&2 ; exit 2 ;;
esac

# -----------------------------------------------------------------------------
# Backup existing configs
# -----------------------------------------------------------------------------
if $BACKUP; then
  echo "📦  Backing up existing User settings in: $CONFIG_USER_DIR"
  for f in \
    "Preferences.sublime-settings" \
    "Package Control.sublime-settings" \
    "LSP.sublime-settings" \
    "Default (Linux).sublime-keymap" \
    "Colorsublime.sublime-settings"; do
      if [[ -f "$CONFIG_USER_DIR/$f" ]]; then
        mv "$CONFIG_USER_DIR/$f" "$CONFIG_USER_DIR/${f}.bak-$TS"
        echo "  • $f → ${f}.bak-$TS"
      fi
  done
fi

# -----------------------------------------------------------------------------
# Ensure directories exist
# -----------------------------------------------------------------------------
mkdir -p "$CONFIG_USER_DIR" "$INSTALLED_PKGS_DIR"

# -----------------------------------------------------------------------------
# Bootstrap Package Control (if missing)
# -----------------------------------------------------------------------------
if [[ ! -f "$INSTALLED_PKGS_DIR/Package Control.sublime-package" ]]; then
  echo "⬇️  Installing Package Control…"
  curl -fsSL "https://packagecontrol.io/Package%20Control.sublime-package" \
       -o "$INSTALLED_PKGS_DIR/Package Control.sublime-package"
else
  echo "✓ Package Control already present"
fi

# -----------------------------------------------------------------------------
# Package Control settings: curated packages list
# -----------------------------------------------------------------------------
cat > "$CONFIG_USER_DIR/Package Control.sublime-settings" << 'EOF'
{
  // -------------------------------------------------------------------------
  // Packages installed automatically by Package Control
  // -------------------------------------------------------------------------
  "installed_packages": [
    // Essentials
    "Package Control",
    "A File Icon",

    // UI / Themes & Colour Schemes
    "Material Theme",
    "Dracula Color Scheme",
    "gruvbox",
    "One Dark Color Scheme",
    "Nord Color Scheme",
    "Colorsublime",

    // Utilities & UX
    "Emmet",
    "SidebarEnhancements",
    "GitGutter",
    "GitSavvy",
    "Terminus",
    "MarkdownPreview",
    "BracketHighlighter",
    "AlignTab",
    "AutoFileName",
    "All Autocomplete",
    "ColorHelper",
    "PackageDev",

    // ────────────────────────────── LSP / Diagnostics ───────────────────────
    "LSP",
    "LSP-pyright",
    "LSP-typescript",
    "LSP-json",
    "LSP-html",
    "LSP-css",
    "LSP-bash",
    "LSP-eslint",
    "SublimeLinter",
    "SublimeLinter-flake8",
    "SublimeLinter-eslint",
    "SublimeLinter-shellcheck",

    // ────────────────────────────── Bash Workflow  ──────────────────────────
    "Bash Completions",
    "ShellCheck",
    "shfmt"
  ]
}
EOF

# -----------------------------------------------------------------------------
# Core Preferences (User)
# -----------------------------------------------------------------------------
cat > "$CONFIG_USER_DIR/Preferences.sublime-settings" << 'EOF'
{
  // ───────────────────────────────── Theme / UI ─────────────────────────────
  "theme": "Material-Theme-Darker.sublime-theme",

  // Automatic colour‑scheme that follows OS light/dark appearance
  "color_scheme": "auto",
  "light_color_scheme": "Packages/Colorsublime-Themes/Breakers.sublime-color-scheme",
  "dark_color_scheme": "Packages/gruvbox/gruvbox (Dark) (Medium).sublime-color-scheme",

  // Fonts
  "font_face": "Fira Code",
  "font_size": 12,
  "font_options": ["gray_antialias", "subpixel_antialias", "ligatures"],

  // Rulers
  "rulers": [80, 100],
  "ruler_style": "solid",
  "ruler_width": 1.0,

  // Tabs & Indentation
  "translate_tabs_to_spaces": true,
  "tab_size": 2,
  "detect_indentation": true,

  // Whitespace Handling
  "draw_white_space": ["selection"],
  "trim_trailing_white_space_on_save": "not_on_caret",
  "trim_only_modified_white_space": true,
  "ensure_newline_at_eof_on_save": true,

  // Autocomplete
  "auto_complete": true,
  "auto_complete_delay": 50,
  "auto_complete_commit_on_tab": false,
  "auto_complete_triggers": [
    { "selector": "source.shell", "characters": "$" },
    { "selector": "source",        "characters": "." }
  ],
  "auto_complete_trailing_spaces": true,

  // Git indicators & mini diff
  "mini_diff": "auto",
  "show_git_status": true,

  // Caret visuals
  "caret_style": "solid",
  "caret_extra_top": 2,
  "caret_extra_bottom": 2,
  "caret_extra_width": 1,

  // Scrolling behaviour
  "scroll_past_end": 0.5,

  // Word wrap adapts to source‑code vs prose
  "word_wrap": "auto",

  // Highlighting
  "highlight_line": true,
  "highlight_gutter": true,
  "highlight_line_number": true,

  // Sidebar
  "sidebar_tree_indent": 2,

  // Window & files
  "open_files_in_new_window": "never",
  "show_full_path": true,

  // Disable Vintage if unused
  "ignored_packages": ["Vintage"]
}
EOF

# -----------------------------------------------------------------------------
# LSP Global Configuration
# -----------------------------------------------------------------------------
cat > "$CONFIG_USER_DIR/LSP.sublime-settings" << 'EOF'
{
  // Enable/disable individual language servers (clients)
  "clients": {
    "bashls":      { "enabled": true },
    "pyright":     { "enabled": true },
    "tsserver":    { "enabled": true },
    "html":        { "enabled": true },
    "cssls":       { "enabled": true },
    "jsonls":      { "enabled": true },
    "eslint":      { "enabled": true }
  },

  // Behaviour
  "log_debug": false,
  "auto_show_diagnostics_panel": true,
  "only_show_lsp_completions": true,
  "format_on_save": true
}
EOF

# -----------------------------------------------------------------------------
# Key Bindings (Linux)
# -----------------------------------------------------------------------------
cat > "$CONFIG_USER_DIR/Default (Linux).sublime-keymap" << 'EOF'
[
  { "keys": ["ctrl+s"],             "command": "save" },
  { "keys": ["ctrl+k", "ctrl+b"], "command": "toggle_side_bar" },
  { "keys": ["ctrl+`"],             "command": "terminus_open" },

  // Wrap selection in double quotes
  {
    "keys": ["ctrl+shift+'"],
    "command": "insert_snippet",
    "args": { "contents": "\"$SELECTION\"" }
  },

  // Quick Coloursublime theme picker
  { "keys": ["ctrl+alt+t"], "command": "colorsublime_install_theme" },

  // LSP helpers
  { "keys": ["ctrl+alt+f"], "command": "lsp_format_document" },
  { "keys": ["f12"],        "command": "lsp_symbol_definition" }
]
EOF

echo "✅ All done! Sublime Text User settings written to: $CONFIG_USER_DIR"
echo "➜ Restart Sublime Text, open any project, and the configured LSP servers will spin‑up automatically."

