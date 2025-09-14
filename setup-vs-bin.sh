#!/usr/bin/env bash
#
# setup-vscode-arch.sh — Automate Visual Studio Code configuration on Arch Linux
# with common extensions, editor settings, keybindings, and CLI tooling.
#
# Usage:
#   ./setup-vscode-arch.sh [--backup]
#
# Options:
#   --backup    Backup existing User settings before overwriting.
#   -h, --help  Show this help message.
#
# Steps performed:
#   1. Optionally back up existing settings/ keybindings.
#   2. Ensure 'code' CLI is installed (via pacman/yay).
#   3. Install a curated set of VS Code extensions.
#   4. Write settings.json and keybindings.json in User config.
#
# Author: OpenAI ChatGPT — May 2025
# Licence: MIT
# -----------------------------------------------------------------------------
set -euo pipefail

# -----------------------------------------------------------------------------
# Paths and environment
# -----------------------------------------------------------------------------
: "${XDG_CONFIG_HOME:=${HOME}/.config}"
VSCODE_USER_DIR="$XDG_CONFIG_HOME/Code/User"
BACKUP=false
TS=$(date +%Y%m%d%H%M%S)

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
case "${1:-}" in
--backup) BACKUP=true ;;
-h | --help)
	cat <<'EOF'
setup-vscode-arch.sh — Automate Visual Studio Code configuration on Arch Linux

Usage:
  $0 [--backup]

Options:
  --backup    Backup existing VS Code User settings before overwriting.
  -h, --help  Show this help message.
EOF
	exit 0
	;;
"") : ;; # no args
*)
	echo "Unknown option: $1" >&2
	exit 2
	;;
esac

# -----------------------------------------------------------------------------
# Backup existing User settings
# -----------------------------------------------------------------------------
if $BACKUP; then
	echo "Backing up existing VS Code User settings..."
	for f in settings.json keybindings.json; do
		if [[ -f "$VSCODE_USER_DIR/$f" ]]; then
			mv "$VSCODE_USER_DIR/$f" "$VSCODE_USER_DIR/${f}.bak-$TS"
			echo "  • $f → ${f}.bak-$TS"
		fi
	done
fi

# -----------------------------------------------------------------------------
# Ensure User config directory exists
# -----------------------------------------------------------------------------
mkdir -p "$VSCODE_USER_DIR"

# -----------------------------------------------------------------------------
# Install 'code' CLI if missing
# -----------------------------------------------------------------------------
if ! command -v code >/dev/null 2>&1; then
	echo "'code' CLI not found. Installing package 'code' via pacman..."
	sudo pacman -S --needed code
else
	echo "'code' CLI already installed."
fi

EXTRA_LANG_EXTENSIONS=(
	mads-hartmann.bash-ide-vscode # Bash LSP
	foxundermoon.shell-format     # Shell formatter
	ms-python.vscode-pylance      # Python LSP
	njpwerner.autodocstring       # Python docstrings
	ms-python.isort               # Python import sorter
	jebbs.plantuml                # UML for Java docs
	doggy8088.netcore-editorconfiggenerator
	dbaeumer.vscode-eslint
	rvest.vs-code-prettier-eslint
	exceptionptr.vscode-prettier-eslint
	esbenp.prettier-vscode
	jinxdash.prettier-rust
	formulahendry.code-runner
	HarryHopkinson.vs-code-runner
	wowbox.code-debuger
	ParthR2031.colorful-comments
	jhessin.node-module-intellisense
	mathematic.vscode-latex
	James-Yu.latex-workshop
	torn4dom4n.latex-support
	tecosaur.latex-utilities
	nickfode.latex-formatter
	OrangeX4.latex-sympy-calculator
	mjpvs.latex-previewer
)

echo "Installing extra language extensions..."
for ext in "${EXTRA_LANG_EXTENSIONS[@]}"; do
	code --install-extension "$ext" --force || true
	echo "  • $ext"
done

# -----------------------------------------------------------------------------
# Install VS Code extensions
# -----------------------------------------------------------------------------
EXTENSIONS=(
	# Productivity
	ms-vscode.cpptools
	ms-python.python
	esbenp.prettier-vscode
	dbaeumer.vscode-eslint
	eamodio.gitlens
	ms-azuretools.vscode-docker
	timonwong.shellcheck
	bbenoist.Vagrant
	bbenoist.Doxygen
	bbenoist.Nix
	timonwong.shellcheck
	bmalehorn.shell-syntax
	jeff-hykin.better-syntax
	peaceshi.syntax-highlight
	foxundermoon.shell-format
	mkhl.shfmt

	# LSP and IntelliSense
	ms-vscode.vscode-typescript-next
	redhat.java
	rust-lang.rust-analyzer

	# Shell & Git
	timonwong.shellcheck
	ms-vscode-remote.remote-ssh

	# Themes & Icons
	PKief.material-icon-theme
	dracula-theme.theme-dracula

	# Markdown & Docs
	yzhang.markdown-all-in-one
	DavidAnson.vscode-markdownlint
)

echo "Installing VS Code extensions..."
for ext in "${EXTENSIONS[@]}"; do
	code --install-extension "$ext" --force || true
	echo "  • $ext"
done

# -----------------------------------------------------------------------------
# Write User settings.json
# -----------------------------------------------------------------------------
cat >"$VSCODE_USER_DIR/settings.json" <<'EOF'
{
  // Theme and Icons
  "workbench.colorTheme": "Dracula",
  "workbench.iconTheme": "material-icon-theme",

  // Font and Editor
  "editor.fontFamily": "Fira Code, Consolas, 'Courier New', monospace",
  "editor.fontLigatures": true,
  "editor.fontSize": 14,
  "editor.lineHeight": 22,

  // Tabs & Indentation
  "editor.tabSize": 2,
  "editor.insertSpaces": true,
  "editor.detectIndentation": true,

  // Rulers
  "editor.rulers": [80, 100],

  // Whitespace
  "editor.renderWhitespace": "selection",
  "editor.trimAutoWhitespace": true,
  "files.trimTrailingWhitespace": true,
  "files.insertFinalNewline": true,

  // Format on save
  "editor.formatOnSave": true,
  "editor.codeActionsOnSave": {
    "source.organizeImports": true,
    "source.fixAll.eslint": true
  },

  // Auto Save
  "files.autoSave": "onFocusChange",

  // Minimap
  "editor.minimap.enabled": true,
  "editor.minimap.renderCharacters": false,

  // Git
  "git.enableSmartCommit": true,
  "git.autofetch": true,

  // Terminal
  "terminal.integrated.fontFamily": "Fira Code",
  "terminal.integrated.shell.linux": "/bin/bash",

  // Extensions
  "python.languageServer": "Pylance",
  "C_Cpp.intelliSenseEngine": "Default"
}
EOF

# -----------------------------------------------------------------------------
# Write User keybindings.json
# -----------------------------------------------------------------------------
cat >"$VSCODE_USER_DIR/keybindings.json" <<'EOF'
[
  // Save with Ctrl+S
  { "key": "ctrl+s", "command": "workbench.action.files.save" },

  // Format Document
  { "key": "ctrl+shift+f", "command": "editor.action.formatDocument" },

  // Toggle Integrated Terminal
  { "key": "ctrl+`", "command": "workbench.action.terminal.toggleTerminal" },

  // GitLens: Toggle File Blame
  { "key": "ctrl+alt+b", "command": "gitlens.toggleFileBlame" }
]
EOF

# -----------------------------------------------------------------------------
# Final message
# -----------------------------------------------------------------------------
echo "✅ VS Code has been configured!"
echo "📂 Settings: $VSCODE_USER_DIR"
echo "🔌 Installed extensions: ${#EXTENSIONS[@]}"
