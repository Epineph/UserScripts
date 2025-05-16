#!/usr/bin/env bash
#
# setup_sublime.sh — Automate Sublime Text configuration with popular packages and tweaks
# Usage: setup_sublime.sh [options]
#
# This script will:
#   • Detect the appropriate Sublime Text configuration directory (3 or 4)
#   • Optionally back up existing settings
#   • Install Package Control
#   • Write Package Control settings (package list)
#   • Write core Preferences (including updated Dracula color scheme path)
#   • Write custom Linux keybindings

set -euo pipefail
IFS=$'\n\t'

# -----------------------------
#  Print help / usage
# -----------------------------
print_help() {
    cat << 'EOF'
Usage: setup_sublime.sh [options]

Options:
  -h, --help      Show this help message and exit.
  -b, --backup    Backup existing Sublime Text config files before overwriting.
  -d, --dry-run   Show what would be done without making any changes.

Description:
  This script automates setup of Sublime Text (3 & 4) by:
    • Detecting the appropriate config directory
    • Optionally backing up existing settings
    • Installing Package Control
    • Writing Package Control and core Preferences
    • (Re)writing custom keybindings
EOF
}

# -----------------------------
#  Default settings
# -----------------------------
BACKUP=false
DRY_RUN=false
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

# Potential config dirs
ST4_USER_DIR="$XDG_CONFIG_HOME/sublime-text/Packages/User"
ST4_PKG_DIR="$XDG_CONFIG_HOME/sublime-text/Installed Packages"
ST3_USER_DIR="$HOME/.config/sublime-text-3/Packages/User"
ST3_PKG_DIR="$HOME/.config/sublime-text-3/Installed Packages"
CONFIG_USER_DIR=""
INSTALLED_PKGS_DIR=""

# -----------------------------
#  Parse command-line options
# -----------------------------
while (( "$#" )); do
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
        -b|--backup)
            BACKUP=true
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            print_help
            exit 1
            ;;
    esac
done

# -----------------------------
#  Detect Sublime Text version
# -----------------------------
if [[ -d "$ST4_USER_DIR" || -d "$ST4_PKG_DIR" ]]; then
    CONFIG_USER_DIR="$ST4_USER_DIR"
    INSTALLED_PKGS_DIR="$ST4_PKG_DIR"
elif [[ -d "$ST3_USER_DIR" || -d "$ST3_PKG_DIR" ]]; then
    CONFIG_USER_DIR="$ST3_USER_DIR"
    INSTALLED_PKGS_DIR="$ST3_PKG_DIR"
else
    # Default to ST4 paths if neither exists
    CONFIG_USER_DIR="$ST4_USER_DIR"
    INSTALLED_PKGS_DIR="$ST4_PKG_DIR"
fi

# -----------------------------
#  Backup helper
# -----------------------------
backup_file() {
    local file="$1"
    if [[ -e "$CONFIG_USER_DIR/$file" ]]; then
        local ts
n        ts=$(date +%Y%m%d%H%M%S)
        echo "Backing up $file → ${file}.bak-$ts"
        [[ "$DRY_RUN" == false ]] && mv "$CONFIG_USER_DIR/$file" "$CONFIG_USER_DIR/${file}.bak-$ts"
    fi
}

# -----------------------------
#  Main execution
# -----------------------------
main() {
    echo "Config dir:    $CONFIG_USER_DIR"
    echo "Packages dir:  $INSTALLED_PKGS_DIR"
    [[ "$DRY_RUN" == true ]] && echo "[DRY RUN] No changes will be made."

    # Ensure directories exist
    [[ "$DRY_RUN" == false ]] && mkdir -p "$CONFIG_USER_DIR" "$INSTALLED_PKGS_DIR"

    # Perform backup if requested
    if [[ "$BACKUP" == true ]]; then
        backup_file "Preferences.sublime-settings"
        backup_file "Package Control.sublime-settings"
        backup_file "Default (Linux).sublime-keymap"
    fi

    # 1. Install Package Control
    echo "Installing Package Control..."
    if [[ "$DRY_RUN" == false ]]; then
        curl -fsSL "https://packagecontrol.io/Package%20Control.sublime-package" \
            -o "$INSTALLED_PKGS_DIR/Package Control.sublime-package"
    fi

    # 2. Package Control settings
    cat > "$CONFIG_USER_DIR/Package Control.sublime-settings" << 'EOF'
{
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

    # 3. Core Preferences
    cat > "$CONFIG_USER_DIR/Preferences.sublime-settings" << 'EOF'
{
    "theme": "Material-Theme.sublime-theme",
    # Updated to use the .sublime-color-scheme file in the Dracula package
    "color_scheme": "Packages/Dracula Color Scheme/Dracula.sublime-color-scheme",
    "font_face": "Fira Code",
    "font_size": 12,
    "translate_tabs_to_spaces": true,
    "tab_size": 4,
    "detect_indentation": true,
    "ensure_newline_at_eof_on_save": true,
    "trim_trailing_white_space_on_save": true,
    "highlight_line": true,
    "word_wrap": false,
    "auto_complete": true,
    "auto_complete_delay": 50,
    "sidebar_tree_indent": 2,
    "ignored_packages": ["Vintage"]
}
EOF

    # 4. Custom keybindings
    cat > "$CONFIG_USER_DIR/Default (Linux).sublime-keymap" << 'EOF'
[
    { "keys": ["ctrl+s"],                "command": "save" },
    { "keys": ["ctrl+k", "ctrl+b"],    "command": "toggle_side_bar" },
    { "keys": ["ctrl+`"],               "command": "terminus_open" },
    { "keys": ["ctrl+shift+'"],         "command": "insert_snippet", "args": { "contents": "\"$SELECTION\"" } }
]
EOF

    echo "✅ Configuration deployed to $CONFIG_USER_DIR"
    echo "Please restart Sublime Text to apply changes."
}

main "$@"
#!/usr/bin/env bash
#
# setup_sublime.sh — Automate Sublime Text configuration with popular packages and tweaks
# Usage: setup_sublime.sh [options]
#
# This script will:
#   • Detect the appropriate Sublime Text configuration directory (3 or 4)
#   • Optionally back up existing settings
#   • Install Package Control
#   • Write Package Control settings (package list)
#   • Write core Preferences (including updated Dracula color scheme path)
#   • Write custom Linux keybindings

set -euo pipefail
IFS=$'\n\t'

# -----------------------------
#  Print help / usage
# -----------------------------
print_help() {
    cat << 'EOF'
Usage: setup_sublime.sh [options]

Options:
  -h, --help      Show this help message and exit.
  -b, --backup    Backup existing Sublime Text config files before overwriting.
  -d, --dry-run   Show what would be done without making any changes.

Description:
  This script automates setup of Sublime Text (3 & 4) by:
    • Detecting the appropriate config directory
    • Optionally backing up existing settings
    • Installing Package Control
    • Writing Package Control and core Preferences
    • (Re)writing custom keybindings
EOF
}

# -----------------------------
#  Default settings
# -----------------------------
BACKUP=false
DRY_RUN=false
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

# Potential config dirs
ST4_USER_DIR="$XDG_CONFIG_HOME/sublime-text/Packages/User"
ST4_PKG_DIR="$XDG_CONFIG_HOME/sublime-text/Installed Packages"
ST3_USER_DIR="$HOME/.config/sublime-text-3/Packages/User"
ST3_PKG_DIR="$HOME/.config/sublime-text-3/Installed Packages"
CONFIG_USER_DIR=""
INSTALLED_PKGS_DIR=""

# -----------------------------
#  Parse command-line options
# -----------------------------
while (( "$#" )); do
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
        -b|--backup)
            BACKUP=true
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            print_help
            exit 1
            ;;
    esac
done

# -----------------------------
#  Detect Sublime Text version
# -----------------------------
if [[ -d "$ST4_USER_DIR" || -d "$ST4_PKG_DIR" ]]; then
    CONFIG_USER_DIR="$ST4_USER_DIR"
    INSTALLED_PKGS_DIR="$ST4_PKG_DIR"
elif [[ -d "$ST3_USER_DIR" || -d "$ST3_PKG_DIR" ]]; then
    CONFIG_USER_DIR="$ST3_USER_DIR"
    INSTALLED_PKGS_DIR="$ST3_PKG_DIR"
else
    # Default to ST4 paths if neither exists
    CONFIG_USER_DIR="$ST4_USER_DIR"
    INSTALLED_PKGS_DIR="$ST4_PKG_DIR"
fi

# -----------------------------
#  Backup helper
# -----------------------------
backup_file() {
    local file="$1"
    if [[ -e "$CONFIG_USER_DIR/$file" ]]; then
        local ts
n        ts=$(date +%Y%m%d%H%M%S)
        echo "Backing up $file → ${file}.bak-$ts"
        [[ "$DRY_RUN" == false ]] && mv "$CONFIG_USER_DIR/$file" "$CONFIG_USER_DIR/${file}.bak-$ts"
    fi
}

# -----------------------------
#  Main execution
# -----------------------------
main() {
    echo "Config dir:    $CONFIG_USER_DIR"
    echo "Packages dir:  $INSTALLED_PKGS_DIR"
    [[ "$DRY_RUN" == true ]] && echo "[DRY RUN] No changes will be made."

    # Ensure directories exist
    [[ "$DRY_RUN" == false ]] && mkdir -p "$CONFIG_USER_DIR" "$INSTALLED_PKGS_DIR"

    # Perform backup if requested
    if [[ "$BACKUP" == true ]]; then
        backup_file "Preferences.sublime-settings"
        backup_file "Package Control.sublime-settings"
        backup_file "Default (Linux).sublime-keymap"
    fi

    # 1. Install Package Control
    echo "Installing Package Control..."
    if [[ "$DRY_RUN" == false ]]; then
        curl -fsSL "https://packagecontrol.io/Package%20Control.sublime-package" \
            -o "$INSTALLED_PKGS_DIR/Package Control.sublime-package"
    fi

    # 2. Package Control settings
    cat > "$CONFIG_USER_DIR/Package Control.sublime-settings" << 'EOF'
{
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

    # 3. Core Preferences
    cat > "$CONFIG_USER_DIR/Preferences.sublime-settings" << 'EOF'
{
    "theme": "Material-Theme.sublime-theme",
    # Updated to use the .sublime-color-scheme file in the Dracula package
    "color_scheme": "Packages/Dracula Color Scheme/Dracula.sublime-color-scheme",
    "font_face": "Fira Code",
    "font_size": 12,
    "translate_tabs_to_spaces": true,
    "tab_size": 4,
    "detect_indentation": true,
    "ensure_newline_at_eof_on_save": true,
    "trim_trailing_white_space_on_save": true,
    "highlight_line": true,
    "word_wrap": false,
    "auto_complete": true,
    "auto_complete_delay": 50,
    "sidebar_tree_indent": 2,
    "ignored_packages": ["Vintage"]
}
EOF

    # 4. Custom keybindings
    cat > "$CONFIG_USER_DIR/Default (Linux).sublime-keymap" << 'EOF'
[
    { "keys": ["ctrl+s"],                "command": "save" },
    { "keys": ["ctrl+k", "ctrl+b"],    "command": "toggle_side_bar" },
    { "keys": ["ctrl+`"],               "command": "terminus_open" },
    { "keys": ["ctrl+shift+'"],         "command": "insert_snippet", "args": { "contents": "\"$SELECTION\"" } }
]
EOF

    echo "✅ Configuration deployed to $CONFIG_USER_DIR"
    echo "Please restart Sublime Text to apply changes."
}

main "$@"
