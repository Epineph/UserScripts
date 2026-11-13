#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup-vscode-linux.sh
#
# Configure VS Code, VS Code Insiders, or VSCodium on Linux for a broad
# scientific/scripting workflow:
#   - Bash/Zsh/sh
#   - Node.js/npm/TypeScript/JavaScript
#   - Python/Jupyter
#   - R/R Markdown/Quarto/radian
#   - Ruby
#   - Rust
#   - Git/GitHub/GitHub CLI
#   - Docker/devcontainers/SSH
#   - Java/C/C++/CMake/Make
#   - OpenAI Codex/ChatGPT, GitHub Copilot, Claude Code
#
# The script is intentionally conservative:
#   - Backups are enabled by default.
#   - Existing JSON can be merged instead of overwritten.
#   - Package installation is optional.
#   - Extension failures warn rather than abort the whole setup.
# -----------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
: "${XDG_CONFIG_HOME:=${HOME}/.config}"
: "${HELP_PAGER:=}"

BACKUP="true"
DRY_RUN="false"
DO_EXTENSIONS="true"
DO_SETTINGS="true"
DO_KEYBINDINGS="true"
DO_PACKAGES="false"
DO_CODE_INSTALL="false"
DO_RADIAN="false"
DO_R_PACKAGES="false"
DO_WORKSPACE_FILES="false"
DO_MCP_TEMPLATE="false"
DO_AI="true"
YES="false"
MODE="merge"
CODE_BIN=""
USER_DIR=""
WORKSPACE_DIR="${PWD}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# -----------------------------------------------------------------------------
# Help and logging
# -----------------------------------------------------------------------------
function _pager_cmd() {
  if [[ -n "${HELP_PAGER}" ]]; then
    printf '%s\n' "${HELP_PAGER}"
    return 0
  fi

  if command -v bat >/dev/null 2>&1; then
    printf '%s\n' \
      'bat --style="grid,header,snip" --italic-text="always"'\
' --theme="gruvbox-dark" --squeeze-blank --squeeze-limit="2"'\
' --force-colorization --terminal-width="auto" --tabs="2"'\
' --paging="never" --chop-long-lines --language=markdown'
    return 0
  fi

  if command -v less >/dev/null 2>&1; then
    printf '%s\n' 'less -R'
    return 0
  fi

  printf '%s\n' 'cat'
}

function _show_help() {
  local pager
  pager="$(_pager_cmd)"

  cat <<'EOF_HELP' | eval "${pager}"
# setup-vscode-linux.sh

Configure VS Code / VS Code Insiders / VSCodium on Linux.

## Usage

```bash
setup-vscode-linux.sh [options]
```

## Core options

```text
--mode MODE             MODE is merge or overwrite. Default: merge.
--backup                Back up existing user files. Default.
--no-backup             Do not back up existing user files.
--dry-run               Print intended actions without writing files.
--code-bin PATH         Use a specific CLI binary: code, code-insiders, codium.
--user-dir PATH         Override the VS Code User directory.
-h, --help              Show this help.
```

## Feature toggles

```text
--extensions            Install extensions. Default.
--no-extensions         Do not install extensions.
--settings              Write or merge settings.json. Default.
--no-settings           Do not write settings.json.
--keybindings           Write or merge keybindings.json. Default.
--no-keybindings        Do not write keybindings.json.
--no-ai                 Skip AI extensions/settings.
```

## Optional installation helpers

```text
--install-packages      Install recommended Linux packages when possible.
--install-code          Try to install VS Code if no code binary is found.
--radian                Install/upgrade radian via pipx.
--r-packages            Install recommended R packages.
--yes                   Non-interactive package-manager mode where supported.
```

## Workspace helpers

```text
--workspace-files       Write .vscode/extensions.json and AI instruction files
                        into the current directory.
--workspace-dir PATH    Directory used with --workspace-files.
--mcp-template          Also write .vscode/mcp.json.example in workspace-dir.
```

## Examples

```bash
# Safe default: install extensions, merge settings/keybindings, backup first.
setup-vscode-linux.sh

# Inspect exactly what would happen.
setup-vscode-linux.sh --dry-run

# Full Arch-style setup with packages, radian, and R packages.
setup-vscode-linux.sh --install-packages --radian --r-packages

# Use VSCodium explicitly.
setup-vscode-linux.sh --code-bin /usr/bin/codium

# Write project recommendations and an MCP example into a repository.
setup-vscode-linux.sh --workspace-files --mcp-template --workspace-dir .

# Replace settings.json/keybindings.json entirely.
setup-vscode-linux.sh --mode overwrite
```

## Notes

- Your ChatGPT/Codex subscription is not stored in settings.json. Install the
  OpenAI extension, open its panel, and sign in interactively.
- GitHub Copilot requires GitHub authentication and a Copilot entitlement.
- Claude Code requires the Anthropic extension and its own login/CLI workflow.
- VSCodium can have Marketplace/Open VSX limitations; extension installation is
  best-effort and warnings are non-fatal.
EOF_HELP
}

function _info() {
  printf '[INFO] %s\n' "$*"
}

function _warn() {
  printf '[WARN] %s\n' "$*" >&2
}

function _die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

function _lower() {
  tr '[:upper:]' '[:lower:]'
}

function _quote_cmd() {
  local arg
  for arg in "$@"; do
    printf '%q ' "${arg}"
  done
  printf '\n'
}

function _run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '[dry-run] '
    _quote_cmd "$@"
    return 0
  fi

  "$@"
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
function _parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        shift
        [[ $# -gt 0 ]] || _die '--mode requires a value'
        MODE="$(printf '%s' "$1" | _lower)"
        ;;
      --backup)
        BACKUP="true"
        ;;
      --no-backup)
        BACKUP="false"
        ;;
      --dry-run)
        DRY_RUN="true"
        ;;
      --extensions)
        DO_EXTENSIONS="true"
        ;;
      --no-extensions)
        DO_EXTENSIONS="false"
        ;;
      --settings)
        DO_SETTINGS="true"
        ;;
      --no-settings)
        DO_SETTINGS="false"
        ;;
      --keybindings)
        DO_KEYBINDINGS="true"
        ;;
      --no-keybindings)
        DO_KEYBINDINGS="false"
        ;;
      --install-packages)
        DO_PACKAGES="true"
        ;;
      --install-code)
        DO_CODE_INSTALL="true"
        ;;
      --radian)
        DO_RADIAN="true"
        ;;
      --r-packages)
        DO_R_PACKAGES="true"
        ;;
      --workspace-files)
        DO_WORKSPACE_FILES="true"
        ;;
      --workspace-dir)
        shift
        [[ $# -gt 0 ]] || _die '--workspace-dir requires a path'
        WORKSPACE_DIR="$1"
        ;;
      --mcp-template)
        DO_MCP_TEMPLATE="true"
        DO_WORKSPACE_FILES="true"
        ;;
      --no-ai)
        DO_AI="false"
        ;;
      --yes|-y)
        YES="true"
        ;;
      --code-bin)
        shift
        [[ $# -gt 0 ]] || _die '--code-bin requires a path or command'
        CODE_BIN="$1"
        ;;
      --user-dir)
        shift
        [[ $# -gt 0 ]] || _die '--user-dir requires a path'
        USER_DIR="$1"
        ;;
      -h|--help)
        _show_help
        exit 0
        ;;
      *)
        _die "Unknown option: $1 (use --help)"
        ;;
    esac
    shift
  done

  case "${MODE}" in
    merge|overwrite) : ;;
    *) _die "--mode must be merge or overwrite; got: ${MODE}" ;;
  esac
}

# -----------------------------------------------------------------------------
# Platform and command detection
# -----------------------------------------------------------------------------
function _require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || _die "Required command missing: ${cmd}"
}

function _detect_package_manager() {
  if command -v pacman >/dev/null 2>&1; then
    printf '%s\n' pacman
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    printf '%s\n' apt
    return 0
  fi

  if command -v dnf >/dev/null 2>&1; then
    printf '%s\n' dnf
    return 0
  fi

  if command -v zypper >/dev/null 2>&1; then
    printf '%s\n' zypper
    return 0
  fi

  if command -v xbps-install >/dev/null 2>&1; then
    printf '%s\n' xbps
    return 0
  fi

  printf '%s\n' unknown
}

function _install_pkg() {
  local pm="$1"
  local pkg="$2"

  case "${pm}" in
    pacman)
      if [[ "${YES}" == "true" ]]; then
        _run sudo pacman -S --needed --noconfirm "${pkg}"
      else
        _run sudo pacman -S --needed "${pkg}"
      fi
      ;;
    apt)
      if [[ "${YES}" == "true" ]]; then
        _run sudo apt-get install -y "${pkg}"
      else
        _run sudo apt-get install "${pkg}"
      fi
      ;;
    dnf)
      if [[ "${YES}" == "true" ]]; then
        _run sudo dnf install -y "${pkg}"
      else
        _run sudo dnf install "${pkg}"
      fi
      ;;
    zypper)
      if [[ "${YES}" == "true" ]]; then
        _run sudo zypper --non-interactive install "${pkg}"
      else
        _run sudo zypper install "${pkg}"
      fi
      ;;
    xbps)
      if [[ "${YES}" == "true" ]]; then
        _run sudo xbps-install -Sy "${pkg}"
      else
        _run sudo xbps-install -S "${pkg}"
      fi
      ;;
    *)
      _warn "No supported package manager detected; skipped package: ${pkg}"
      return 1
      ;;
  esac
}

function _install_recommended_packages() {
  [[ "${DO_PACKAGES}" == "true" ]] || return 0

  local pm
  pm="$(_detect_package_manager)"
  _info "Detected package manager: ${pm}"

  local -a packages=()

  case "${pm}" in
    pacman)
      packages=(
        bash zsh git github-cli openssh curl wget jq ripgrep fd unzip tar zstd
        nodejs npm shellcheck shfmt python python-pip python-pipx
        python-virtualenv python-ruff python-black python-isort python-mypy
        python-pytest r base-devel ruby rustup rust-analyzer lldb gdb cmake make
        gcc pkgconf jdk-openjdk docker docker-compose lua-language-server
      )
      ;;
    apt)
      packages=(
        bash zsh git gh openssh-client curl wget jq ripgrep fd-find unzip tar
        zstd nodejs npm shellcheck shfmt python3 python3-pip python3-pipx
        python3-venv r-base ruby-full rustup lldb gdb cmake make gcc pkg-config
        default-jdk docker.io docker-compose-plugin lua-language-server
      )
      ;;
    dnf)
      packages=(
        bash zsh git gh openssh-clients curl wget jq ripgrep fd-find unzip tar
        zstd nodejs npm ShellCheck shfmt python3 python3-pip pipx R ruby rustup
        rust-analyzer lldb gdb cmake make gcc pkgconf java-latest-openjdk-devel
        docker docker-compose lua-language-server
      )
      ;;
    zypper)
      packages=(
        bash zsh git gh openssh curl wget jq ripgrep fd unzip tar zstd nodejs
        npm ShellCheck shfmt python3 python3-pip python3-pipx R-base ruby rustup
        rust-analyzer lldb gdb cmake make gcc pkgconf java-21-openjdk-devel
        docker docker-compose lua-language-server
      )
      ;;
    xbps)
      packages=(
        bash zsh git github-cli openssh curl wget jq ripgrep fd unzip tar zstd
        nodejs npm ShellCheck shfmt python3 python3-pipx R ruby rustup
        rust-analyzer lldb gdb cmake make gcc pkg-config openjdk21 docker
        docker-compose lua-language-server
      )
      ;;
    *)
      _warn 'Unsupported package manager; package installation skipped.'
      return 0
      ;;
  esac

  local pkg
  for pkg in "${packages[@]}"; do
    _info "Ensuring package: ${pkg}"
    if ! _install_pkg "${pm}" "${pkg}"; then
      _warn "Could not install package: ${pkg}"
    fi
  done
}

function _install_code_if_requested() {
  [[ "${DO_CODE_INSTALL}" == "true" ]] || return 0

  if command -v code >/dev/null 2>&1; then
    return 0
  fi

  local pm
  pm="$(_detect_package_manager)"

  case "${pm}" in
    pacman)
      _info "Installing Arch package: code"
      _install_pkg pacman code || true
      ;;
    apt|dnf|zypper)
      _warn "Install Microsoft's repository first if 'code' is unavailable."
      _install_pkg "${pm}" code || true
      ;;
    *)
      _warn 'Cannot auto-install VS Code for this distribution.'
      ;;
  esac
}

function _detect_code_bin() {
  if [[ -n "${CODE_BIN}" ]]; then
    if [[ -x "${CODE_BIN}" ]]; then
      CODE_BIN="$(realpath "${CODE_BIN}")"
      return 0
    fi

    if command -v "${CODE_BIN}" >/dev/null 2>&1; then
      CODE_BIN="$(command -v "${CODE_BIN}")"
      return 0
    fi

    _die "--code-bin not found or not executable: ${CODE_BIN}"
  fi

  local candidate
  for candidate in code code-insiders codium; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      CODE_BIN="$(command -v "${candidate}")"
      return 0
    fi
  done

  _install_code_if_requested

  for candidate in code code-insiders codium; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      CODE_BIN="$(command -v "${candidate}")"
      return 0
    fi
  done

  if [[ "${DRY_RUN}" == "true" ]]; then
    CODE_BIN="code"
    _warn "No VS Code CLI found; dry-run will display commands using: code"
    return 0
  fi

  _die "No VS Code CLI found. Install code/codium or pass --code-bin."
}

function _detect_user_dir() {
  [[ -n "${USER_DIR}" ]] && return 0

  case "$(basename "${CODE_BIN}")" in
    codium)
      USER_DIR="${XDG_CONFIG_HOME}/VSCodium/User"
      ;;
    code-insiders)
      USER_DIR="${XDG_CONFIG_HOME}/Code - Insiders/User"
      ;;
    *)
      USER_DIR="${XDG_CONFIG_HOME}/Code/User"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Backups and atomic writes
# -----------------------------------------------------------------------------
function _backup_file() {
  local path="$1"
  [[ "${BACKUP}" == "true" ]] || return 0
  [[ -f "${path}" ]] || return 0

  _run cp -a -- "${path}" "${path}.bak-${TIMESTAMP}"
  _info "Backup: ${path}.bak-${TIMESTAMP}"
}

function _atomic_write() {
  local dest="$1"
  local tmp

  tmp="$(mktemp)"
  cat > "${tmp}"

  if [[ -f "${dest}" ]] && cmp -s "${tmp}" "${dest}"; then
    rm -f -- "${tmp}"
    _info "Unchanged: ${dest}"
    return 0
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    _info "Would write: ${dest}"
    rm -f -- "${tmp}"
    return 0
  fi

  install -m 0644 -- "${tmp}" "${dest}"
  rm -f -- "${tmp}"
  _info "Written: ${dest}"
}

function _json_merge_settings() {
  local existing_path="$1"
  local desired_path="$2"

  _require_cmd python3

  python3 - "${existing_path}" "${desired_path}" <<'PY'
import json
import sys
from pathlib import Path

existing_path = Path(sys.argv[1])
desired_path = Path(sys.argv[2])


def read_json(path, fallback):
  if not path.exists():
    return fallback
  try:
    return json.loads(path.read_text(encoding="utf-8"))
  except Exception:
    return fallback


def deep_merge(left, right):
  if isinstance(left, dict) and isinstance(right, dict):
    merged = dict(left)
    for key, value in right.items():
      merged[key] = deep_merge(merged.get(key), value)
    return merged
  return right

existing = read_json(existing_path, {})
desired = read_json(desired_path, {})
merged = deep_merge(existing if isinstance(existing, dict) else {}, desired)
print(json.dumps(merged, indent=2, ensure_ascii=False))
PY
}

function _json_merge_keybindings() {
  local existing_path="$1"
  local desired_path="$2"

  _require_cmd python3

  python3 - "${existing_path}" "${desired_path}" <<'PY'
import json
import sys
from pathlib import Path

existing_path = Path(sys.argv[1])
desired_path = Path(sys.argv[2])


def read_json(path, fallback):
  if not path.exists():
    return fallback
  try:
    return json.loads(path.read_text(encoding="utf-8"))
  except Exception:
    return fallback


def key(entry):
  return (entry.get("key"), entry.get("command"), entry.get("when"))

existing = read_json(existing_path, [])
desired = read_json(desired_path, [])
merged = []
seen = set()

for entry in existing if isinstance(existing, list) else []:
  if isinstance(entry, dict):
    merged.append(entry)
    seen.add(key(entry))

for entry in desired if isinstance(desired, list) else []:
  if isinstance(entry, dict) and key(entry) not in seen:
    merged.append(entry)
    seen.add(key(entry))

print(json.dumps(merged, indent=2, ensure_ascii=False))
PY
}

# -----------------------------------------------------------------------------
# Runtime discovery used by settings.json
# -----------------------------------------------------------------------------
function _detect_radian_or_r() {
  if command -v radian >/dev/null 2>&1; then
    command -v radian
    return 0
  fi

  if [[ -x "${HOME}/.local/bin/radian" ]]; then
    printf '%s\n' "${HOME}/.local/bin/radian"
    return 0
  fi

  if command -v R >/dev/null 2>&1; then
    command -v R
    return 0
  fi

  printf '%s\n' ''
}

function _detect_r_path() {
  if command -v R >/dev/null 2>&1; then
    command -v R
    return 0
  fi

  printf '%s\n' ''
}

function _detect_default_terminal_profile() {
  if command -v zsh >/dev/null 2>&1; then
    printf '%s\n' zsh
    return 0
  fi

  if command -v bash >/dev/null 2>&1; then
    printf '%s\n' bash
    return 0
  fi

  printf '%s\n' sh
}

function _detect_java_home() {
  local candidate
  for candidate in \
    /usr/lib/jvm/java-21-openjdk \
    /usr/lib/jvm/java-22-openjdk \
    /usr/lib/jvm/java-23-openjdk \
    /usr/lib/jvm/java-24-openjdk \
    /usr/lib/jvm/java-25-openjdk \
    /usr/lib/jvm/default \
    /usr/lib/jvm/default-runtime \
    /usr/lib/jvm/java-17-openjdk; do
    if [[ -d "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  printf '%s\n' ''
}

function _detect_node_path() {
  if command -v node >/dev/null 2>&1; then
    command -v node
    return 0
  fi

  printf '%s\n' ''
}

function _detect_python_path() {
  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return 0
  fi

  if command -v python >/dev/null 2>&1; then
    command -v python
    return 0
  fi

  printf '%s\n' ''
}

function _detect_ruby_path() {
  if command -v ruby >/dev/null 2>&1; then
    command -v ruby
    return 0
  fi

  printf '%s\n' ''
}

# -----------------------------------------------------------------------------
# Extension lists
# -----------------------------------------------------------------------------
function _extensions_list() {
  cat <<'EOF_EXT'
# --- Core editing -------------------------------------------------------------
EditorConfig.EditorConfig
PKief.material-icon-theme
usernamehw.errorlens
Gruntfuggly.todo-tree
streetsidesoftware.code-spell-checker
mechatroner.rainbow-csv

# --- Git and GitHub -----------------------------------------------------------
eamodio.gitlens
mhutchie.git-graph
GitHub.vscode-pull-request-github
GitHub.vscode-github-actions
GitHub.remotehub

# --- AI assistants ------------------------------------------------------------
__AI__openai.chatgpt
__AI__GitHub.copilot
__AI__GitHub.copilot-chat
__AI__anthropic.claude-code

# --- Shell / Linux / config files --------------------------------------------
mads-hartmann.bash-ide-vscode
timonwong.shellcheck
mkhl.shfmt
foxundermoon.shell-format
redhat.vscode-yaml
redhat.vscode-xml
tamasfe.even-better-toml
mikestead.dotenv

# --- Python / Jupyter ---------------------------------------------------------
ms-python.python
ms-python.vscode-pylance
ms-python.debugpy
charliermarsh.ruff
ms-python.black-formatter
ms-toolsai.jupyter

# --- R / R Markdown / Quarto --------------------------------------------------
REditorSupport.r
RDebugger.r-debugger
quarto.quarto

# --- Node.js / npm / TypeScript / JavaScript ---------------------------------
dbaeumer.vscode-eslint
esbenp.prettier-vscode
christian-kohler.path-intellisense
christian-kohler.npm-intellisense
stylelint.vscode-stylelint

# --- Ruby ---------------------------------------------------------------------
Shopify.ruby-lsp
KoichiSasada.vscode-rdbg
castwide.solargraph

# --- Rust ---------------------------------------------------------------------
rust-lang.rust-analyzer
vadimcn.vscode-lldb
serayuzgur.crates

# --- Containers / SSH / remote ------------------------------------------------
ms-azuretools.vscode-docker
ms-vscode-remote.remote-ssh
ms-vscode-remote.remote-containers
ms-vscode.remote-explorer

# --- C / C++ / CMake / Make ---------------------------------------------------
ms-vscode.cpptools
ms-vscode.cmake-tools
ms-vscode.makefile-tools

# --- Java ---------------------------------------------------------------------
redhat.java
vscjava.vscode-java-debug
vscjava.vscode-java-dependency
vscjava.vscode-maven
vscjava.vscode-gradle

# --- Markdown / LaTeX ---------------------------------------------------------
yzhang.markdown-all-in-one
DavidAnson.vscode-markdownlint
James-Yu.latex-workshop

# --- Lua ----------------------------------------------------------------------
sumneko.lua
EOF_EXT
}

function _install_extensions() {
  [[ "${DO_EXTENSIONS}" == "true" ]] || return 0

  local ext raw
  _info "Installing VS Code extensions via: ${CODE_BIN}"

  while IFS= read -r raw; do
    raw="${raw%%#*}"
    raw="${raw//[[:space:]]/}"
    [[ -n "${raw}" ]] || continue

    if [[ "${raw}" == __AI__* ]]; then
      [[ "${DO_AI}" == "true" ]] || continue
      ext="${raw#__AI__}"
    else
      ext="${raw}"
    fi

    _info "Extension: ${ext}"
    if [[ "${DRY_RUN}" == "true" ]]; then
      printf '[dry-run] %q --install-extension %q --force\n' \
        "${CODE_BIN}" "${ext}"
      continue
    fi

    if ! "${CODE_BIN}" --install-extension "${ext}" --force; then
      _warn "Failed to install extension: ${ext}"
    fi
  done < <(_extensions_list)
}

# -----------------------------------------------------------------------------
# Desired JSON content
# -----------------------------------------------------------------------------
function _desired_settings_json() {
  _require_cmd python3

  local term_profile rterm rpath java_home node_path python_path ruby_path
  term_profile="$(_detect_default_terminal_profile)"
  rterm="$(_detect_radian_or_r)"
  rpath="$(_detect_r_path)"
  java_home="$(_detect_java_home)"
  node_path="$(_detect_node_path)"
  python_path="$(_detect_python_path)"
  ruby_path="$(_detect_ruby_path)"

  python3 - \
    "${term_profile}" \
    "${rterm}" \
    "${rpath}" \
    "${java_home}" \
    "${node_path}" \
    "${python_path}" \
    "${ruby_path}" \
    "${DO_AI}" <<'PY'
import json
import os
import sys

(
  term_profile,
  rterm,
  rpath,
  java_home,
  node_path,
  python_path,
  ruby_path,
  do_ai,
) = sys.argv[1:]

profiles = {}
if os.path.exists("/usr/bin/zsh"):
  profiles["zsh"] = {"path": "/usr/bin/zsh", "args": ["-l"]}
if os.path.exists("/usr/bin/bash"):
  profiles["bash"] = {"path": "/usr/bin/bash", "args": ["-l"]}
if os.path.exists("/usr/bin/fish"):
  profiles["fish"] = {"path": "/usr/bin/fish", "args": ["-l"]}
if os.path.exists("/usr/bin/nu"):
  profiles["nu"] = {"path": "/usr/bin/nu"}
if not profiles:
  profiles["sh"] = {"path": "/bin/sh"}

settings = {
  "workbench.colorTheme": "Default Dark Modern",
  "workbench.iconTheme": "material-icon-theme",
  "workbench.startupEditor": "none",
  "workbench.editor.enablePreview": False,
  "window.commandCenter": True,
  "editor.fontFamily": "Fira Code, JetBrains Mono, Hack, monospace",
  "editor.fontLigatures": True,
  "editor.fontSize": 14,
  "editor.lineHeight": 22,
  "editor.tabSize": 2,
  "editor.insertSpaces": True,
  "editor.detectIndentation": True,
  "editor.rulers": [81, 100, 120],
  "editor.wordWrap": "off",
  "editor.renderWhitespace": "selection",
  "editor.renderControlCharacters": False,
  "editor.minimap.enabled": True,
  "editor.minimap.renderCharacters": False,
  "editor.guides.indentation": True,
  "editor.guides.bracketPairs": True,
  "editor.bracketPairColorization.enabled": True,
  "editor.inlineSuggest.enabled": True,
  "editor.stickyScroll.enabled": True,
  "editor.suggestSelection": "first",
  "editor.acceptSuggestionOnCommitCharacter": False,
  "editor.formatOnSave": True,
  "editor.formatOnPaste": False,
  "editor.codeActionsOnSave": {
    "source.fixAll": "explicit",
    "source.organizeImports": "explicit",
  },
  "files.autoSave": "onFocusChange",
  "files.insertFinalNewline": True,
  "files.trimTrailingWhitespace": True,
  "files.trimFinalNewlines": True,
  "files.encoding": "utf8",
  "files.eol": "\n",
  "files.associations": {
    "*.Rprofile": "r",
    "*.Renviron": "shellscript",
    "*.zsh": "shellscript",
    "*.bash": "shellscript",
    ".env*": "dotenv",
    "PKGBUILD": "shellscript",
  },
  "search.useIgnoreFiles": True,
  "search.useGlobalIgnoreFiles": True,
  "search.followSymlinks": False,
  "search.smartCase": True,
  "search.exclude": {
    "**/.git": True,
    "**/.Rproj.user": True,
    "**/.mypy_cache": True,
    "**/.pytest_cache": True,
    "**/.ruff_cache": True,
    "**/__pycache__": True,
    "**/node_modules": True,
    "**/dist": True,
    "**/build": True,
    "**/target": True,
    "**/.quarto": True,
    "**/.venv": True,
    "**/renv/library": True,
  },
  "explorer.confirmDelete": False,
  "explorer.confirmDragAndDrop": False,
  "git.enableSmartCommit": True,
  "git.autofetch": True,
  "git.confirmSync": False,
  "git.openRepositoryInParentFolders": "always",
  "git.inputValidation": "always",
  "github.gitAuthentication": True,
  "terminal.integrated.fontFamily": "Fira Code, JetBrains Mono, monospace",
  "terminal.integrated.fontSize": 13,
  "terminal.integrated.scrollback": 200000,
  "terminal.integrated.cursorBlinking": True,
  "terminal.integrated.defaultProfile.linux": term_profile,
  "terminal.integrated.profiles.linux": profiles,
  "telemetry.telemetryLevel": "off",
  "security.workspace.trust.untrustedFiles": "open",
  "extensions.ignoreRecommendations": False,
  "update.mode": "manual",
  "[shellscript]": {
    "editor.defaultFormatter": "mkhl.shfmt",
    "editor.tabSize": 2,
    "editor.insertSpaces": True,
    "files.eol": "\n",
  },
  "bashIde.enableSourceErrorDiagnostics": True,
  "bashIde.shellcheckPath": "shellcheck",
  "shellcheck.enable": True,
  "shellcheck.run": "onType",
  "shellformat.flag": "-i 2 -ci -bn -sr",
  "[python]": {
    "editor.defaultFormatter": "charliermarsh.ruff",
    "editor.formatOnSave": True,
    "editor.codeActionsOnSave": {
      "source.fixAll": "explicit",
      "source.organizeImports": "explicit",
    },
  },
  "python.analysis.typeCheckingMode": "basic",
  "python.analysis.inlayHints.variableTypes": True,
  "python.analysis.inlayHints.functionReturnTypes": True,
  "python.analysis.autoImportCompletions": True,
  "python.analysis.diagnosticMode": "workspace",
  "python.terminal.activateEnvironment": True,
  "python.REPL.sendToNativeREPL": False,
  "ruff.importStrategy": "fromEnvironment",
  "ruff.nativeServer": "auto",
  "ruff.organizeImports": True,
  "black-formatter.importStrategy": "fromEnvironment",
  "jupyter.askForKernelRestart": False,
  "jupyter.interactiveWindow.textEditor.executeSelection": True,
  "notebook.lineNumbers": "on",
  "notebook.output.textLineLimit": 200,
  "r.bracketedPaste": True,
  "r.alwaysUseActiveTerminal": True,
  "r.plot.useHttpgd": True,
  "r.sessionWatcher": True,
  "r.rterm.option": ["--no-save", "--no-restore"],
  "[r]": {
    "editor.tabSize": 2,
    "editor.insertSpaces": True,
    "editor.formatOnSave": False,
  },
  "[rmd]": {
    "editor.wordWrap": "on",
    "editor.formatOnSave": False,
  },
  "[quarto]": {
    "editor.wordWrap": "on",
    "editor.formatOnSave": False,
  },
  "[ruby]": {
    "editor.defaultFormatter": "Shopify.ruby-lsp",
    "editor.tabSize": 2,
    "editor.insertSpaces": True,
  },
  "rubyLsp.enabledFeatures": {
    "codeActions": True,
    "codeLens": True,
    "completion": True,
    "definition": True,
    "diagnostics": True,
    "documentHighlights": True,
    "documentLink": True,
    "documentSymbols": True,
    "foldingRanges": True,
    "formatting": True,
    "hover": True,
    "inlayHint": True,
    "onTypeFormatting": True,
    "selectionRanges": True,
    "semanticHighlighting": True,
    "signatureHelp": True,
    "typeHierarchy": True,
    "workspaceSymbol": True,
  },
  "[rust]": {
    "editor.defaultFormatter": "rust-lang.rust-analyzer",
    "editor.formatOnSave": True,
  },
  "rust-analyzer.cargo.autoreload": True,
  "rust-analyzer.check.command": "clippy",
  "rust-analyzer.inlayHints.bindingModeHints.enable": True,
  "rust-analyzer.inlayHints.closingBraceHints.enable": True,
  "rust-analyzer.inlayHints.typeHints.enable": True,
  "[javascript]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode",
    "editor.formatOnSave": True,
  },
  "[javascriptreact]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode",
    "editor.formatOnSave": True,
  },
  "[typescript]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode",
    "editor.formatOnSave": True,
  },
  "[typescriptreact]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode",
    "editor.formatOnSave": True,
  },
  "[json]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode",
  },
  "[jsonc]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode",
  },
  "[yaml]": {
    "editor.defaultFormatter": "redhat.vscode-yaml",
  },
  "eslint.validate": [
    "javascript",
    "javascriptreact",
    "typescript",
    "typescriptreact",
  ],
  "prettier.useEditorConfig": True,
  "npm.packageManager": "npm",
  "npm.enableRunFromFolder": True,
  "[markdown]": {
    "editor.wordWrap": "on",
    "editor.quickSuggestions": {
      "comments": "off",
      "strings": "off",
      "other": "off",
    },
  },
  "markdown.preview.breaks": False,
  "markdown.extension.toc.updateOnSave": False,
  "markdownlint.config": {
    "MD013": False,
    "MD033": False,
    "MD034": False,
  },
  "latex-workshop.latex.autoBuild.run": "never",
  "latex-workshop.view.pdf.viewer": "tab",
  "cmake.configureOnOpen": False,
  "makefile.configureOnOpen": False,
  "C_Cpp.default.cppStandard": "c++20",
  "C_Cpp.default.cStandard": "c17",
  "java.configuration.updateBuildConfiguration": "interactive",
  "java.compile.nullAnalysis.mode": "automatic",
  "Lua.hint.enable": True,
  "Lua.runtime.version": "LuaJIT",
  "Lua.diagnostics.globals": ["vim"],
  "[lua]": {
    "editor.tabSize": 2,
    "editor.insertSpaces": True,
  },
}

if do_ai == "true":
  settings.update(
    {
      "github.copilot.enable": {
        "*": True,
        "plaintext": False,
        "markdown": True,
        "scminput": False,
      },
      "github.copilot.editor.enableAutoCompletions": True,
      "chat.commandCenter.enabled": True,
    }
  )

if rterm:
  settings["r.rterm.linux"] = rterm
if rpath:
  settings["r.rpath.linux"] = rpath
if java_home:
  settings["java.jdt.ls.java.home"] = java_home
  settings["java.import.gradle.java.home"] = java_home
  settings["java.import.maven.java.home"] = java_home
  settings["java.configuration.runtimes"] = [
    {"name": "JavaSE-21", "path": java_home, "default": True}
  ]
if node_path:
  settings["typescript.tsserver.nodePath"] = node_path
if python_path:
  settings["python.defaultInterpreterPath"] = python_path
if ruby_path:
  settings["rubyLsp.rubyExecutablePath"] = ruby_path

print(json.dumps(settings, indent=2, ensure_ascii=False))
PY
}

function _desired_keybindings_json() {
  cat <<'EOF_KEYS'
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
    "key": "ctrl+k ctrl+f",
    "command": "editor.action.formatDocument"
  },
  {
    "key": "alt+z",
    "command": "editor.action.toggleWordWrap"
  },
  {
    "key": "ctrl+shift+/",
    "command": "editor.action.blockComment",
    "when": "editorTextFocus && !editorReadonly"
  },
  {
    "key": "ctrl+enter",
    "command": "python.execSelectionInTerminal",
    "when": "editorTextFocus && editorLangId == 'python'"
  },
  {
    "key": "ctrl+enter",
    "command": "r.runSelection",
    "when": "editorTextFocus && editorLangId == 'r'"
  },
  {
    "key": "ctrl+shift+enter",
    "command": "workbench.action.terminal.runSelectedText",
    "when": "editorTextFocus"
  },
  {
    "key": "ctrl+alt+b",
    "command": "gitlens.toggleFileBlame"
  },
  {
    "key": "ctrl+alt+g",
    "command": "workbench.view.scm"
  },
  {
    "key": "ctrl+shift+i",
    "command": "workbench.action.chat.open"
  }
]
EOF_KEYS
}

function _write_settings() {
  [[ "${DO_SETTINGS}" == "true" ]] || return 0

  local settings_path desired_tmp merged_tmp
  settings_path="${USER_DIR}/settings.json"
  desired_tmp="$(mktemp)"
  merged_tmp="$(mktemp)"

  _desired_settings_json > "${desired_tmp}"
  _backup_file "${settings_path}"

  if [[ "${MODE}" == "merge" && -f "${settings_path}" ]]; then
    _json_merge_settings "${settings_path}" "${desired_tmp}" > "${merged_tmp}"
    _atomic_write "${settings_path}" < "${merged_tmp}"
  else
    _atomic_write "${settings_path}" < "${desired_tmp}"
  fi

  rm -f -- "${desired_tmp}" "${merged_tmp}"
}

function _write_keybindings() {
  [[ "${DO_KEYBINDINGS}" == "true" ]] || return 0

  local keybindings_path desired_tmp merged_tmp
  keybindings_path="${USER_DIR}/keybindings.json"
  desired_tmp="$(mktemp)"
  merged_tmp="$(mktemp)"

  _desired_keybindings_json > "${desired_tmp}"
  _backup_file "${keybindings_path}"

  if [[ "${MODE}" == "merge" && -f "${keybindings_path}" ]]; then
    _json_merge_keybindings "${keybindings_path}" "${desired_tmp}" > "${merged_tmp}"
    _atomic_write "${keybindings_path}" < "${merged_tmp}"
  else
    _atomic_write "${keybindings_path}" < "${desired_tmp}"
  fi

  rm -f -- "${desired_tmp}" "${merged_tmp}"
}

# -----------------------------------------------------------------------------
# Optional R/radian setup
# -----------------------------------------------------------------------------
function _install_radian() {
  [[ "${DO_RADIAN}" == "true" ]] || return 0

  if ! command -v pipx >/dev/null 2>&1; then
    _warn 'pipx is missing. Use --install-packages or install python-pipx.'
    return 0
  fi

  _info 'Ensuring pipx path'
  _run pipx ensurepath || true

  if pipx list --short 2>/dev/null | grep -Fxq radian; then
    _info 'Upgrading radian via pipx'
    _run pipx upgrade radian || true
  else
    _info 'Installing radian via pipx'
    _run pipx install radian || true
  fi
}

function _install_r_packages() {
  [[ "${DO_R_PACKAGES}" == "true" ]] || return 0

  if ! command -v Rscript >/dev/null 2>&1; then
    _warn 'Rscript is missing; cannot install R packages.'
    return 0
  fi

  local r_code
  r_code='packages <- c(
    "languageserver", "jsonlite", "rlang", "httpgd", "lintr",
    "styler", "renv", "rmarkdown", "quarto", "vscDebugger",
    "data.table", "tidyverse"
  )
  repos <- "https://cloud.r-project.org"
  missing <- packages[!vapply(packages, requireNamespace, FALSE, quietly = TRUE)]
  if (length(missing)) install.packages(missing, repos = repos)
  '

  _info 'Installing recommended R packages when missing'
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '[dry-run] Rscript -e %q\n' "${r_code}"
    return 0
  fi

  Rscript -e "${r_code}" || _warn 'Some R packages failed to install.'
}

# -----------------------------------------------------------------------------
# Workspace recommendations and MCP template
# -----------------------------------------------------------------------------
function _workspace_extensions_json() {
  python3 - "${DO_AI}" <<'PY'
import json
import sys

do_ai = sys.argv[1] == "true"
recommendations = []
for line in sys.stdin:
  line = line.split("#", 1)[0].strip()
  if not line:
    continue
  if line.startswith("__AI__"):
    if do_ai:
      recommendations.append(line.removeprefix("__AI__"))
  else:
    recommendations.append(line)

print(json.dumps({"recommendations": recommendations}, indent=2))
PY
}

function _write_workspace_files() {
  [[ "${DO_WORKSPACE_FILES}" == "true" ]] || return 0
  _require_cmd python3

  local vscode_dir github_dir ext_path instr_path mcp_path
  vscode_dir="${WORKSPACE_DIR}/.vscode"
  github_dir="${WORKSPACE_DIR}/.github"
  ext_path="${vscode_dir}/extensions.json"
  instr_path="${github_dir}/copilot-instructions.md"
  mcp_path="${vscode_dir}/mcp.json.example"

  _run mkdir -p -- "${vscode_dir}" "${github_dir}"

  _extensions_list | _workspace_extensions_json > /tmp/vscode-ext-json-$$
  _atomic_write "${ext_path}" < /tmp/vscode-ext-json-$$
  rm -f -- /tmp/vscode-ext-json-$$

  cat <<'EOF_INSTR' | _atomic_write "${instr_path}"
# Repository instructions for AI coding assistants

## Style

- Prefer clear, explicit code over compact cleverness.
- Keep shell scripts POSIX-compatible only when explicitly requested.
- For Bash/Zsh scripts, prefer two-space indentation and functions written as
  `function name() { ... }`.
- Keep line width near 81 columns when practical.
- Preserve scientific/statistical correctness over stylistic convenience.

## Safety

- Do not silently delete, overwrite, or move user data.
- Prefer dry-run modes and explicit backups for filesystem-changing scripts.
- Explain destructive commands before using them.

## Languages

- Python: prefer typed functions, explicit exceptions, ruff-compatible style.
- R: prefer reproducible scripts, explicit package loading, and clear model
  assumptions.
- Shell: run ShellCheck mentally or with `shellcheck` before finalizing.
EOF_INSTR

  if [[ "${DO_MCP_TEMPLATE}" == "true" ]]; then
    cat <<'EOF_MCP' | _atomic_write "${mcp_path}"
{
  "servers": {
    "filesystem-workspace-example": {
      "type": "stdio",
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-filesystem",
        "${workspaceFolder}"
      ]
    }
  }
}
EOF_MCP
  fi
}

# -----------------------------------------------------------------------------
# Status and post-run notes
# -----------------------------------------------------------------------------
function _print_status() {
  cat <<EOF_STATUS

Configuration summary
---------------------
code bin:         ${CODE_BIN}
user dir:         ${USER_DIR}
mode:             ${MODE}
backup:           ${BACKUP}
dry-run:          ${DRY_RUN}
extensions:       ${DO_EXTENSIONS}
settings:         ${DO_SETTINGS}
keybindings:      ${DO_KEYBINDINGS}
packages:         ${DO_PACKAGES}
ai extensions:    ${DO_AI}
workspace files:  ${DO_WORKSPACE_FILES}
workspace dir:    ${WORKSPACE_DIR}
EOF_STATUS
}

function _print_post_notes() {
  cat <<'EOF_NOTES'

Post-run notes
--------------
1. OpenAI / ChatGPT / Codex
   Open the OpenAI/Codex panel in VS Code and sign in. Your ChatGPT plan is
   authenticated interactively; it is not configured by writing an API key into
   settings.json.

2. GitHub / GitHub CLI / Copilot
   Run:

     gh auth login
     gh auth status

   Then sign into GitHub inside VS Code if prompted. Copilot requires a GitHub
   Copilot entitlement; installing the extension alone is not sufficient.

3. Claude Code
   Open the Claude Code extension and follow Anthropic's sign-in flow. If you
   prefer the terminal-first workflow, install Claude Code CLI separately and
   use VS Code's integrated terminal.

4. R support
   Best results require the R packages languageserver, jsonlite, rlang, httpgd,
   lintr, styler, renv, rmarkdown, quarto, and optionally vscDebugger.
   Re-run this script with --r-packages to install missing packages.

5. Python support
   Use project-local virtual environments when possible:

     python -m venv .venv
     source .venv/bin/activate
     python -m pip install -U pip ruff black ipykernel pytest mypy

6. Rust support
   If rustup was newly installed, run:

     rustup default stable
     rustup component add rustfmt clippy

7. Docker/devcontainers
   Installing the Docker extension does not start Docker. On most systems you
   still need to enable the daemon and add your user to the docker group.
EOF_NOTES
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
function main() {
  _parse_args "$@"
  _install_recommended_packages
  _install_code_if_requested
  _detect_code_bin
  _detect_user_dir

  if [[ "${DO_SETTINGS}" == "true" || \
        "${DO_KEYBINDINGS}" == "true" || \
        "${DO_WORKSPACE_FILES}" == "true" ]]; then
    _require_cmd python3
  fi

  _print_status

  _run mkdir -p -- "${USER_DIR}"
  _install_radian
  _install_extensions
  _write_settings
  _write_keybindings
  _install_r_packages
  _write_workspace_files

  _print_post_notes
}

main "$@"
