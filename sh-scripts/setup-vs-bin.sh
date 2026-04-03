#!/usr/bin/env bash

set -euo pipefail

#===============================================================================
# setup-vs-bin-corrected.sh
#
# Configure Visual Studio Code on Arch Linux for a shell / Python / R /
# PowerShell-centric workflow, while also preparing support for Node.js,
# JavaScript, TypeScript, Lua, Markdown, YAML, Docker, C/C++, Rust, Java,
# and LaTeX.
#
# This script:
#   1. Detects or installs VS Code (`code`) on Arch Linux.
#   2. Optionally backs up existing user settings.
#   3. Installs a curated set of extensions.
#   4. Writes settings.json and keybindings.json.
#   5. Optionally installs recommended companion packages.
#   6. Optionally installs radian with pipx.
#
# Notes:
#   - Modern VS Code uses terminal profiles and defaultProfile settings.
#   - `editor.codeActionsOnSave` should use enum values such as `explicit`.
#   - On Arch Linux, radian should be installed with pipx rather than
#     `pip --user`.
#   - The Arch package `bash-language-server` depends on `nodejs`, which can
#     conflict with installed `nodejs-lts-*` packages. This script avoids
#     replacing an LTS runtime merely to satisfy that package.
#
# Usage:
#   ./setup-vs-bin-corrected.sh
#   ./setup-vs-bin-corrected.sh --backup
#   ./setup-vs-bin-corrected.sh --install-packages
#   ./setup-vs-bin-corrected.sh --install-packages --radian
#   ./setup-vs-bin-corrected.sh --backup --install-packages --radian
#
#===============================================================================

#-------------------------------------------------------------------------------
# Defaults
#-------------------------------------------------------------------------------
BACKUP=false
INSTALL_PACKAGES=false
SKIP_PACKAGES=false
INSTALL_RADIAN=false
CODE_BIN=""
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

: "${XDG_CONFIG_HOME:=${HOME}/.config}"
VSCODE_USER_DIR="${XDG_CONFIG_HOME}/Code/User"
SETTINGS_FILE="${VSCODE_USER_DIR}/settings.json"
KEYBINDINGS_FILE="${VSCODE_USER_DIR}/keybindings.json"

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
function show_help() {
  cat <<'EOF_HELP'
setup-vs-bin-corrected.sh

Configure Visual Studio Code on Arch Linux for a scientific and scripting-
heavy workflow.

Usage:
  setup-vs-bin-corrected.sh [options]

Options:
  --backup            Back up existing settings.json and keybindings.json.
  --install-packages  Install recommended Arch helper packages.
  --skip-packages     Do not install helper packages.
  --radian            Install or upgrade radian via pipx.
  --code-bin PATH     Use a specific `code` executable.
  -h, --help          Show this help text.

What gets configured:
  - VS Code extensions for Bash, Python, Jupyter, R, PowerShell, Lua,
    Markdown, YAML, Docker, Git, C/C++, CMake, Rust, Java, and LaTeX.
  - Language-specific formatter defaults where they are low-risk.
  - Linux terminal profile defaults for zsh, bash, and fish.
  - Practical keybindings rather than novelty bindings.

Important package notes:
  - Bash tooling is materially better with bash-language-server, shellcheck,
    and shfmt.
  - Python tooling is materially better with python-black and python-ruff.
  - R tooling is materially better with R packages such as:
      languageserver, jsonlite, rlang, httpgd
  - radian is optional and is installed via pipx, not `pip --user`.
  - If an LTS Node.js runtime is already installed, this script does not
    replace it merely to satisfy a helper package.

Examples:
  setup-vs-bin-corrected.sh
  setup-vs-bin-corrected.sh --backup
  setup-vs-bin-corrected.sh --install-packages
  setup-vs-bin-corrected.sh --install-packages --radian
  setup-vs-bin-corrected.sh --backup --install-packages --radian
  setup-vs-bin-corrected.sh --code-bin /usr/bin/code
EOF_HELP
}

#-------------------------------------------------------------------------------
# Logging
#-------------------------------------------------------------------------------
function info() {
  printf '[INFO] %s\n' "$*"
}

function warn() {
  printf '[WARN] %s\n' "$*" >&2
}

function die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

#-------------------------------------------------------------------------------
# Argument parsing
#-------------------------------------------------------------------------------
function parse_args() {
  while (($# > 0)); do
    case "$1" in
      --backup)
        BACKUP=true
        ;;
      --install-packages)
        INSTALL_PACKAGES=true
        ;;
      --skip-packages)
        SKIP_PACKAGES=true
        ;;
      --radian)
        INSTALL_RADIAN=true
        ;;
      --code-bin)
        shift
        (($# > 0)) || die "Missing argument for --code-bin"
        CODE_BIN="$1"
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
    shift
  done

  if [[ "$INSTALL_PACKAGES" == true && "$SKIP_PACKAGES" == true ]]; then
    die "Use either --install-packages or --skip-packages, not both"
  fi
}

#-------------------------------------------------------------------------------
# Platform and binary checks
#-------------------------------------------------------------------------------
function require_arch() {
  [[ -f /etc/arch-release ]] || \
    die "This script is written for Arch Linux or Arch-based systems"
}

function detect_code_bin() {
  if [[ -n "$CODE_BIN" ]]; then
    [[ -x "$CODE_BIN" ]] || die "Specified --code-bin is not executable"
    return 0
  fi

  if command -v code >/dev/null 2>&1; then
    CODE_BIN="$(command -v code)"
    return 0
  fi

  info "VS Code CLI not found; installing package 'code' from Arch repos"
  sudo pacman -S --needed code

  command -v code >/dev/null 2>&1 || \
    die "Installation finished, but 'code' is still not on PATH"

  CODE_BIN="$(command -v code)"
}

#-------------------------------------------------------------------------------
# Node and radian helpers
#-------------------------------------------------------------------------------
function have_node_runtime() {
  command -v node >/dev/null 2>&1
}

function have_node_lts_package() {
  pacman -Qq 2>/dev/null | grep -Eq '^nodejs-lts-'
}

function should_skip_bash_language_server_pkg() {
  if pacman -Q bash-language-server >/dev/null 2>&1; then
    return 1
  fi

  if have_node_lts_package && ! pacman -Q nodejs >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

function ensure_node_runtime() {
  if have_node_runtime; then
    info "Existing Node.js runtime detected: $(node --version)"
    info "Leaving current Node.js installation unchanged"
    return 0
  fi

  info "No Node.js runtime detected; installing nodejs and npm"
  sudo pacman -S --needed nodejs npm
}

function ensure_pipx() {
  if command -v pipx >/dev/null 2>&1; then
    return 0
  fi

  info "Installing python-pipx via pacman"
  sudo pacman -S --needed python-pipx

  command -v pipx >/dev/null 2>&1 || \
    die "pipx is not available after installation attempt"
}

function install_radian() {
  ensure_pipx

  info "Ensuring pipx path"
  pipx ensurepath >/dev/null 2>&1 || true

  if pipx list --short 2>/dev/null | grep -Fxq 'radian'; then
    info "radian already installed; upgrading with pipx"
    pipx upgrade radian || true
    return 0
  fi

  info "Installing radian with pipx"
  pipx install radian
}

function choose_r_term() {
  if command -v radian >/dev/null 2>&1; then
    command -v radian
    return 0
  fi

  if [[ -x "${HOME}/.local/bin/radian" ]]; then
    printf '%s\n' "${HOME}/.local/bin/radian"
    return 0
  fi

  printf '%s\n' "R"
}

#-------------------------------------------------------------------------------
# Backups
#-------------------------------------------------------------------------------
function backup_existing_files() {
  [[ "$BACKUP" == true ]] || return 0

  mkdir -p "$VSCODE_USER_DIR"

  local file
  for file in "$SETTINGS_FILE" "$KEYBINDINGS_FILE"; do
    if [[ -f "$file" ]]; then
      cp -a "$file" "${file}.bak-${TIMESTAMP}"
      info "Backed up $(basename "$file") -> ${file}.bak-${TIMESTAMP}"
    fi
  done
}

#-------------------------------------------------------------------------------
# Recommended system packages
#-------------------------------------------------------------------------------
function install_arch_packages() {
  [[ "$SKIP_PACKAGES" == true ]] && return 0
  [[ "$INSTALL_PACKAGES" == true ]] || return 0

  local -a pkgs=(
    shellcheck
    shfmt
    python-black
    python-ruff
    lua-language-server
    rust-analyzer
    jdk21-openjdk
    cmake
    make
    gcc
    ripgrep
    fd
    unzip
  )

  if should_skip_bash_language_server_pkg; then
    warn "Skipping bash-language-server package to avoid replacing an"
    warn "installed nodejs-lts package with nodejs"
  else
    pkgs+=(bash-language-server)
  fi

  info "Installing recommended Arch packages"
  sudo pacman -S --needed "${pkgs[@]}"

  ensure_node_runtime
}

#-------------------------------------------------------------------------------
# Extension install helpers
#-------------------------------------------------------------------------------
function install_extension() {
  local ext="$1"
  info "Installing extension: ${ext}"
  "$CODE_BIN" --install-extension "$ext" --force >/dev/null 2>&1 || \
    warn "Failed to install extension: ${ext}"
}

function install_extensions() {
  local -a extensions=(
    EditorConfig.EditorConfig
    eamodio.gitlens
    ms-vscode-remote.remote-ssh
    yzhang.markdown-all-in-one
    DavidAnson.vscode-markdownlint
    PKief.material-icon-theme
    esbenp.prettier-vscode
    mads-hartmann.bash-ide-vscode
    timonwong.shellcheck
    mkhl.shfmt
    ms-python.python
    ms-python.vscode-pylance
    ms-python.black-formatter
    charliermarsh.ruff
    ms-toolsai.jupyter
    REditorSupport.r
    ms-vscode.PowerShell
    sumneko.lua
    redhat.vscode-yaml
    ms-azuretools.vscode-docker
    ms-vscode.cpptools
    ms-vscode.cmake-tools
    ms-vscode.makefile-tools
    rust-lang.rust-analyzer
    redhat.java
    James-Yu.latex-workshop
  )

  local ext
  for ext in "${extensions[@]}"; do
    install_extension "$ext"
  done
}

#-------------------------------------------------------------------------------
# Write settings
#-------------------------------------------------------------------------------
function write_settings() {
  mkdir -p "$VSCODE_USER_DIR"

  local r_term
  r_term="$(choose_r_term)"

  cat > "$SETTINGS_FILE" <<EOF_SETTINGS
{
  "workbench.colorTheme": "Default Dark Modern",
  "workbench.iconTheme": "material-icon-theme",

  "editor.fontFamily": "Fira Code, JetBrains Mono, Hack, monospace",
  "editor.fontLigatures": true,
  "editor.fontSize": 14,
  "editor.lineHeight": 22,
  "editor.tabSize": 2,
  "editor.insertSpaces": true,
  "editor.detectIndentation": true,
  "editor.rulers": [80, 81, 100, 120],
  "editor.wordWrap": "off",
  "editor.renderWhitespace": "selection",
  "editor.renderControlCharacters": false,
  "editor.minimap.enabled": true,
  "editor.minimap.renderCharacters": false,
  "editor.guides.indentation": true,
  "editor.guides.bracketPairs": true,
  "editor.bracketPairColorization.enabled": true,
  "editor.inlineSuggest.enabled": true,
  "editor.stickyScroll.enabled": true,
  "editor.formatOnSave": true,
  "editor.formatOnPaste": false,
  "editor.codeActionsOnSave": {
    "source.fixAll": "explicit",
    "source.organizeImports": "explicit"
  },

  "files.autoSave": "onFocusChange",
  "files.insertFinalNewline": true,
  "files.trimTrailingWhitespace": true,
  "files.trimFinalNewlines": true,
  "files.encoding": "utf8",
  "files.eol": "\\n",
  "files.associations": {
    "*.Rprofile": "r",
    "*.Renviron": "shellscript",
    "*.zsh": "shellscript",
    ".env*": "dotenv"
  },

  "search.useIgnoreFiles": true,
  "search.useGlobalIgnoreFiles": true,
  "search.followSymlinks": false,
  "search.smartCase": true,
  "search.exclude": {
    "**/.git": true,
    "**/.Rproj.user": true,
    "**/.mypy_cache": true,
    "**/.pytest_cache": true,
    "**/__pycache__": true,
    "**/node_modules": true,
    "**/dist": true,
    "**/build": true,
    "**/.quarto": true
  },

  "explorer.confirmDelete": false,
  "explorer.confirmDragAndDrop": false,

  "git.enableSmartCommit": true,
  "git.autofetch": true,
  "git.confirmSync": false,
  "git.openRepositoryInParentFolders": "always",

  "terminal.integrated.fontFamily": "Fira Code, JetBrains Mono, monospace",
  "terminal.integrated.fontSize": 13,
  "terminal.integrated.scrollback": 200000,
  "terminal.integrated.cursorBlinking": true,
  "terminal.integrated.defaultProfile.linux": "zsh",
  "terminal.integrated.profiles.linux": {
    "bash": {
      "path": "/usr/bin/bash",
      "args": ["-l"]
    },
    "zsh": {
      "path": "/usr/bin/zsh",
      "args": ["-l"]
    },
    "fish": {
      "path": "/usr/bin/fish",
      "args": ["-l"]
    }
  },

  "telemetry.telemetryLevel": "off",
  "security.workspace.trust.untrustedFiles": "open",
  "extensions.ignoreRecommendations": false,
  "update.mode": "manual",

  "[shellscript]": {
    "editor.defaultFormatter": "mkhl.shfmt",
    "editor.tabSize": 2,
    "files.eol": "\\n"
  },
  "bashIde.enableSourceErrorDiagnostics": true,
  "shellcheck.enable": true,
  "shellcheck.run": "onType",

  "[python]": {
    "editor.defaultFormatter": "ms-python.black-formatter",
    "editor.formatOnSave": true,
    "editor.codeActionsOnSave": {
      "source.fixAll": "explicit",
      "source.organizeImports": "explicit"
    }
  },
  "python.analysis.typeCheckingMode": "basic",
  "python.analysis.inlayHints.variableTypes": true,
  "python.analysis.inlayHints.functionReturnTypes": true,
  "python.analysis.autoImportCompletions": true,
  "python.terminal.activateEnvironment": true,
  "python.REPL.sendToNativeREPL": false,
  "black-formatter.importStrategy": "fromEnvironment",
  "ruff.importStrategy": "fromEnvironment",
  "ruff.organizeImports": true,

  "jupyter.askForKernelRestart": false,
  "jupyter.interactiveWindow.textEditor.executeSelection": true,
  "notebook.lineNumbers": "on",
  "notebook.output.textLineLimit": 200,

  "r.bracketedPaste": true,
  "r.alwaysUseActiveTerminal": true,
  "r.plot.useHttpgd": true,
  "r.sessionWatcher": true,
  "r.rterm.linux": "${r_term}",
  "r.rterm.option": [
    "--no-save",
    "--no-restore"
  ],

  "[r]": {
    "editor.tabSize": 2,
    "editor.insertSpaces": true,
    "editor.formatOnSave": false
  },
  "[rmd]": {
    "editor.wordWrap": "on"
  },

  "powershell.codeFormatting.useCorrectCasing": true,
  "powershell.codeFormatting.openBraceOnSameLine": true,
  "[powershell]": {
    "editor.tabSize": 2,
    "editor.insertSpaces": true
  },

  "Lua.hint.enable": true,
  "Lua.runtime.version": "LuaJIT",
  "Lua.diagnostics.globals": [
    "vim"
  ],
  "[lua]": {
    "editor.tabSize": 2,
    "editor.insertSpaces": true
  },

  "[javascript]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode",
    "editor.formatOnSave": true
  },
  "[javascriptreact]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode",
    "editor.formatOnSave": true
  },
  "[typescript]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode",
    "editor.formatOnSave": true
  },
  "[typescriptreact]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode",
    "editor.formatOnSave": true
  },
  "[json]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode"
  },
  "[jsonc]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode"
  },
  "[yaml]": {
    "editor.defaultFormatter": "redhat.vscode-yaml"
  },
  "[markdown]": {
    "editor.wordWrap": "on",
    "editor.quickSuggestions": {
      "comments": "off",
      "strings": "off",
      "other": "off"
    }
  },

  "prettier.useEditorConfig": true,

  "[rust]": {
    "editor.formatOnSave": true
  },
  "rust-analyzer.cargo.autoreload": true,

  "cmake.configureOnOpen": false,
  "makefile.configureOnOpen": false,

  "java.configuration.updateBuildConfiguration": "interactive",

  "latex-workshop.latex.autoBuild.run": "never",
  "latex-workshop.view.pdf.viewer": "tab",

  "markdownlint.config": {
    "MD013": false,
    "MD033": false
  }
}
EOF_SETTINGS
}

#-------------------------------------------------------------------------------
# Write keybindings
#-------------------------------------------------------------------------------
function write_keybindings() {
  mkdir -p "$VSCODE_USER_DIR"

  cat > "$KEYBINDINGS_FILE" <<'EOF_KEYS'
[
  {
    "key": "ctrl+alt+t",
    "command": "workbench.action.terminal.toggleTerminal"
  },
  {
    "key": "ctrl+shift+s",
    "command": "workbench.action.files.saveAll"
  },
  {
    "key": "ctrl+alt+b",
    "command": "gitlens.toggleFileBlame"
  },
  {
    "key": "ctrl+alt+r",
    "command": "r.runSelection"
  },
  {
    "key": "ctrl+enter",
    "command": "r.runSelection",
    "when": "editorTextFocus && editorLangId == 'r'"
  },
  {
    "key": "ctrl+enter",
    "command": "python.execSelectionInTerminal",
    "when": "editorTextFocus && editorLangId == 'python'"
  },
  {
    "key": "ctrl+shift+enter",
    "command": "workbench.action.terminal.runSelectedText"
  },
  {
    "key": "alt+z",
    "command": "editor.action.toggleWordWrap"
  },
  {
    "key": "ctrl+shift+/",
    "command": "editor.action.blockComment"
  },
  {
    "key": "ctrl+k ctrl+f",
    "command": "editor.action.formatDocument"
  }
]
EOF_KEYS
}

#-------------------------------------------------------------------------------
# Post-run guidance
#-------------------------------------------------------------------------------
function print_post_install_notes() {
  cat <<'EOF_NOTES'

Post-install notes:

1. R inside VS Code
   Install these in R for the best experience:

     install.packages(c(
       "languageserver",
       "jsonlite",
       "rlang",
       "httpgd"
     ))

   Optional additions:

     install.packages(c("lintr", "styler", "data.table", "renv"))

2. Radian
   This script installs radian with pipx when you pass --radian.

   Manual equivalent:

     sudo pacman -S --needed python-pipx
     pipx ensurepath
     pipx install radian

   If radian is not installed or not desired, the script falls back to plain R.

3. PowerShell
   If you actually intend to run pwsh on Arch, install PowerShell separately.
   The VS Code extension alone does not provide the shell.

4. Restart VS Code
   Fully quit and reopen VS Code after the script finishes.
EOF_NOTES
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
function main() {
  parse_args "$@"
  require_arch
  detect_code_bin
  backup_existing_files
  install_arch_packages

  if [[ "$INSTALL_RADIAN" == true ]]; then
    install_radian
  fi

  install_extensions
  write_settings
  write_keybindings

  info "VS Code user directory: ${VSCODE_USER_DIR}"
  info "Settings written to: ${SETTINGS_FILE}"
  info "Keybindings written to: ${KEYBINDINGS_FILE}"

  print_post_install_notes
}

main "$@"
