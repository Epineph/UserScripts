#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup-vs-bin.sh
#
# Configure VS Code / VSCodium on Arch Linux:
#   - install a curated set of extensions
#   - write (or merge) User settings.json + keybindings.json
#   - optionally back up existing configuration
#
# Notes:
#   - LaTeX math rendering in Markdown is handled by VS Code preview (KaTeX).
#   - For fully faithful LaTeX math output, use Quarto / Pandoc to HTML/PDF.
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
MODE="overwrite"              # overwrite | merge
CODE_BIN=""                   # autodetect if empty
USER_DIR=""                   # autodetect if empty
TIMESTAMP="$(date +%Y%m%d%H%M%S)"

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------
function _pager_cmd() {
  if [[ -n "${HELP_PAGER}" ]]; then
    printf '%s\n' "${HELP_PAGER}"
    return 0
  fi

  if command -v less >/dev/null 2>&1; then
    printf '%s\n' "less -R"
    return 0
  fi

  printf '%s\n' "cat"
}

function _show_help() {
  local pager
  pager="$(_pager_cmd)"

  cat <<'EOF' | eval "${pager}"
setup-vs-bin.sh — Configure VS Code / VSCodium on Arch Linux

USAGE
  setup-vs-bin.sh [OPTIONS]

OPTIONS
  --backup, --no-backup
      Enable/disable backup of existing settings.json and keybindings.json.

  --extensions, --no-extensions
      Enable/disable extension installation.

  --settings, --no-settings
      Enable/disable settings.json writing/merging.

  --keybindings, --no-keybindings
      Enable/disable keybindings.json writing/merging.

  --mode MODE
      MODE is one of: overwrite, merge
        overwrite: replace files entirely
        merge:     merge settings; merge keybindings by (key,command)

  --code-bin PATH
      Use a specific VS Code CLI binary (e.g. /usr/bin/code, /usr/bin/codium).

  --user-dir PATH
      Use a specific VS Code User directory (overrides autodetection).
      Example:
        ~/.config/Code/User
        ~/.config/VSCodium/User

  --dry-run
      Print actions without modifying anything.

  -h, --help
      Show this help.

ENVIRONMENT
  HELP_PAGER
      Override the pager used for --help output (default: less -R, else cat).

EXAMPLES
  setup-vs-bin.sh --backup --mode merge
  setup-vs-bin.sh --no-extensions --settings --keybindings
  setup-vs-bin.sh --code-bin /usr/bin/codium --mode overwrite
EOF
}

# -----------------------------------------------------------------------------
# Args (case-insensitive values for --mode)
# -----------------------------------------------------------------------------
function _lower() {
  tr '[:upper:]' '[:lower:]'
}

function _die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

function _run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '[dry-run] %s\n' "$*" >&2
    return 0
  fi
  eval "$@"
}

function _parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backup) BACKUP="true" ;;
      --no-backup) BACKUP="false" ;;

      --extensions) DO_EXTENSIONS="true" ;;
      --no-extensions) DO_EXTENSIONS="false" ;;

      --settings) DO_SETTINGS="true" ;;
      --no-settings) DO_SETTINGS="false" ;;

      --keybindings) DO_KEYBINDINGS="true" ;;
      --no-keybindings) DO_KEYBINDINGS="false" ;;

      --mode)
        shift
        [[ $# -gt 0 ]] || _die "--mode requires a value"
        MODE="$(printf '%s' "$1" | _lower)"
        ;;
      --code-bin)
        shift
        [[ $# -gt 0 ]] || _die "--code-bin requires a path"
        CODE_BIN="$1"
        ;;
      --user-dir)
        shift
        [[ $# -gt 0 ]] || _die "--user-dir requires a path"
        USER_DIR="$1"
        ;;
      --dry-run) DRY_RUN="true" ;;

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
    overwrite|merge) : ;;
    *) _die "--mode must be overwrite or merge (got: ${MODE})" ;;
  esac
}

# -----------------------------------------------------------------------------
# VS Code detection
# -----------------------------------------------------------------------------
function _detect_code_bin() {
  if [[ -n "${CODE_BIN}" ]]; then
    command -v "${CODE_BIN}" >/dev/null 2>&1 || \
      _die "--code-bin not found/executable: ${CODE_BIN}"
    return 0
  fi

  if command -v code >/dev/null 2>&1; then
    CODE_BIN="code"
    return 0
  fi

  if command -v codium >/dev/null 2>&1; then
    CODE_BIN="codium"
    return 0
  fi

  _die "Neither 'code' nor 'codium' found in PATH. Install one, or pass --code-bin"
}

function _detect_user_dir() {
  if [[ -n "${USER_DIR}" ]]; then
    return 0
  fi

  # Prefer matching directory names for the chosen CLI.
  if [[ "${CODE_BIN}" == "codium" ]]; then
    USER_DIR="${XDG_CONFIG_HOME}/VSCodium/User"
    return 0
  fi

  USER_DIR="${XDG_CONFIG_HOME}/Code/User"
}

# -----------------------------------------------------------------------------
# Backups + atomic writes
# -----------------------------------------------------------------------------
function _backup_file() {
  local path="$1"
  [[ -f "${path}" ]] || return 0
  _run "mv -- '${path}' '${path}.bak-${TIMESTAMP}'"
}

function _atomic_write() {
  local dest="$1"
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}"

  if [[ -f "${dest}" ]]; then
    if cmp -s "${tmp}" "${dest}"; then
      rm -f "${tmp}"
      printf 'unchanged: %s\n' "${dest}"
      return 0
    fi
  fi

  _run "install -m 0644 '${tmp}' '${dest}'"
  rm -f "${tmp}"
  printf 'written:   %s\n' "${dest}"
}

# -----------------------------------------------------------------------------
# JSON merge helpers (python3)
# -----------------------------------------------------------------------------
function _require_python3() {
  command -v python3 >/dev/null 2>&1 || \
    _die "python3 is required for merge mode"
}

function _json_merge_settings() {
  # Deep-merge dicts: existing <- desired (desired wins on conflicts)
  # Usage: _json_merge_settings EXISTING_PATH DESIRED_JSON
  local existing_path="$1"
  local desired_json="$2"

  _require_python3

  python3 - "${existing_path}" "${desired_json}" <<'PY'
import json, sys
from pathlib import Path

existing_path = Path(sys.argv[1])
desired_json = sys.argv[2]

def deep_merge(a, b):
  if isinstance(a, dict) and isinstance(b, dict):
    out = dict(a)
    for k, v in b.items():
      if k in out:
        out[k] = deep_merge(out[k], v)
      else:
        out[k] = v
    return out
  return b

existing = {}
if existing_path.exists():
  try:
    existing = json.loads(existing_path.read_text(encoding="utf-8"))
  except Exception:
    existing = {}

desired = json.loads(desired_json)
merged = deep_merge(existing if isinstance(existing, dict) else {}, desired)
print(json.dumps(merged, indent=2, ensure_ascii=False, sort_keys=True))
PY
}

function _json_merge_keybindings() {
  # Merge by unique (key, command), desired appended after existing.
  local existing_path="$1"
  local desired_json="$2"

  _require_python3

  python3 - "${existing_path}" "${desired_json}" <<'PY'
import json, sys
from pathlib import Path

existing_path = Path(sys.argv[1])
desired_json = sys.argv[2]

def norm(entry):
  k = entry.get("key")
  c = entry.get("command")
  return (k, c)

existing = []
if existing_path.exists():
  try:
    existing = json.loads(existing_path.read_text(encoding="utf-8"))
  except Exception:
    existing = []

desired = json.loads(desired_json)

merged = []
seen = set()

for e in existing if isinstance(existing, list) else []:
  if isinstance(e, dict):
    t = norm(e)
    merged.append(e)
    seen.add(t)

for e in desired if isinstance(desired, list) else []:
  if isinstance(e, dict):
    t = norm(e)
    if t not in seen:
      merged.append(e)
      seen.add(t)

print(json.dumps(merged, indent=2, ensure_ascii=False))
PY
}

# -----------------------------------------------------------------------------
# Desired extensions + config
# -----------------------------------------------------------------------------
function _extensions_list() {
  # One ID per line. Keep this curated; remove duplicates by design.
  cat <<'EOF'
charliermarsh.ruff
DavidAnson.vscode-markdownlint
EditorConfig.EditorConfig
REditorSupport.r
James-Yu.latex-workshop
eamodio.gitlens
esbenp.prettier-vscode
mads-hartmann.bash-ide-vscode
mkhl.shfmt
ms-azuretools.vscode-docker
ms-python.python
ms-python.vscode-pylance
ms-toolsai.jupyter
ms-vscode-remote.remote-ssh
redhat.vscode-yaml
timonwong.shellcheck
yzhang.markdown-all-in-one
EOF
}

function _desired_settings_json() {
  # Stable, conservative defaults; per-language formatters prevent conflicts.
  cat <<'EOF'
{
  "editor.tabSize": 2,
  "editor.insertSpaces": true,
  "editor.detectIndentation": true,
  "editor.rulers": [81, 100],
  "editor.formatOnSave": true,

  "files.trimTrailingWhitespace": true,
  "files.insertFinalNewline": true,

  "git.autofetch": true,

  "terminal.integrated.defaultProfile.linux": "bash",

  "markdown.math.enabled": true,

  "[python]": {
    "editor.defaultFormatter": "charliermarsh.ruff",
    "editor.formatOnSave": true
  },
  "[markdown]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode"
  },
  "[shellscript]": {
    "editor.defaultFormatter": "mkhl.shfmt"
  },
  "[quarto]": {
    "editor.formatOnSave": false
  },

  "python.languageServer": "Pylance"
}
EOF
}

function _desired_keybindings_json() {
  cat <<'EOF'
[
  {
    "key": "ctrl+`",
    "command": "workbench.action.terminal.toggleTerminal"
  },
  {
    "key": "ctrl+shift+f",
    "command": "editor.action.formatDocument"
  }
]
EOF
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------
function _install_extensions() {
  local ext
  printf 'installing extensions via: %s\n' "${CODE_BIN}"

  while IFS= read -r ext; do
    [[ -n "${ext}" ]] || continue
    if [[ "${DRY_RUN}" == "true" ]]; then
      printf '[dry-run] %s --install-extension %s --force\n' "${CODE_BIN}" "${ext}"
      continue
    fi
    "${CODE_BIN}" --install-extension "${ext}" --force >/dev/null 2>&1 || \
      printf 'warn: failed to install extension: %s\n' "${ext}" >&2
    printf '  - %s\n' "${ext}"
  done < <(_extensions_list)
}

function _write_settings() {
  local settings_path="${USER_DIR}/settings.json"
  local desired
  desired="$(_desired_settings_json)"

  if [[ "${BACKUP}" == "true" ]]; then
    _backup_file "${settings_path}"
  fi

  if [[ "${MODE}" == "merge" && -f "${settings_path}" ]]; then
    _json_merge_settings "${settings_path}" "${desired}" | \
      _atomic_write "${settings_path}"
    return 0
  fi

  printf '%s\n' "${desired}" | _atomic_write "${settings_path}"
}

function _write_keybindings() {
  local keybindings_path="${USER_DIR}/keybindings.json"
  local desired
  desired="$(_desired_keybindings_json)"

  if [[ "${BACKUP}" == "true" ]]; then
    _backup_file "${keybindings_path}"
  fi

  if [[ "${MODE}" == "merge" && -f "${keybindings_path}" ]]; then
    _json_merge_keybindings "${keybindings_path}" "${desired}" | \
      _atomic_write "${keybindings_path}"
    return 0
  fi

  printf '%s\n' "${desired}" | _atomic_write "${keybindings_path}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
function main() {
  _parse_args "$@"
  _detect_code_bin
  _detect_user_dir

  _run "mkdir -p -- '${USER_DIR}'"

  printf 'code bin:  %s\n' "${CODE_BIN}"
  printf 'user dir:  %s\n' "${USER_DIR}"
  printf 'mode:      %s\n' "${MODE}"
  printf 'backup:    %s\n' "${BACKUP}"
  printf 'dry-run:   %s\n' "${DRY_RUN}"

  if [[ "${DO_EXTENSIONS}" == "true" ]]; then
    _install_extensions
  fi

  if [[ "${DO_SETTINGS}" == "true" ]]; then
    _write_settings
  fi

  if [[ "${DO_KEYBINDINGS}" == "true" ]]; then
    _write_keybindings
  fi
}

main "$@"

