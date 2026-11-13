#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# mkedit
#
# Create a file, create missing parent directories, optionally paste clipboard
# content into it, then open it in an editor by default.
# -----------------------------------------------------------------------------

set -euo pipefail

PROG="${0##*/}"
LOG_ROOT="${HOME}/.logs/mkedit"

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
function die() {
  printf '%s: error: %s\n' "$PROG" "$*" >&2
  exit 1
}

function info() {
  if [[ "${VERBOSE}" == "true" ]]; then
    printf '%s: %s\n' "$PROG" "$*" >&2
  fi
}

function usage() {
  cat <<'EOF_USAGE'
mkedit

Create a file, create missing parent directories, optionally paste clipboard
content into it, and open it in an editor by default.

Usage:
  mkedit [options] <file>

Options:
  -e, --editor <cmd>           Editor command. Defaults to $EDITOR, then nvim,
                               vim, code, subl, micro, nano, vi.
  -n, --no-edit                Create/update the file, but do not open editor.
  -p, --paste, --paste-clipboard
                               Write clipboard content into the file.
  -d, --dump-output [cat|bat]  Print/view the file instead of editing it.
                               Default viewer: cat.
      --print [cat|bat]        Alias for --dump-output.
      --view [cat|bat]         Alias for --dump-output.
  -r, --replace                Blank existing file before opening/editing.
  -b, --blank                  Alias for --replace.
      --edit-empty             Alias for --replace.
      --edit-blank             Alias for --replace.
  -v, --verbose                Print details about created dirs, backups, etc.
  -h, --help                   Show help.

Option flags are case-insensitive. For example, --Verbose, --verbOSE, and -V
are all treated as --verbose.

If the file already exists, its previous content is backed up under:
  $HOME/.logs/mkedit/YYYY-MM-DD/

Examples:
  mkedit notes/today.md
  mkedit -e nvim scripts/test.sh
  mkedit --no-edit nested/path/file.txt
  mkedit --paste-clipboard clips/from-clipboard.md
  mkedit --dump-output bat notes/today.md
  mkedit --blank --editor 'code --wait' config/example.conf
EOF_USAGE
}

# -----------------------------------------------------------------------------
# Path and command helpers
# -----------------------------------------------------------------------------
function lower() {
  printf '%s\n' "${1,,}"
}

function expand_leading_tilde() {
  local path="$1"

  case "$path" in
    '~')
      printf '%s\n' "$HOME"
      ;;
    '~/'*)
      printf '%s\n' "${HOME}/${path#~/}"
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}

function command_exists() {
  command -v -- "$1" >/dev/null 2>&1
}

function first_existing_command() {
  local cmd

  for cmd in "$@"; do
    if command_exists "$cmd"; then
      printf '%s\n' "$cmd"
      return 0
    fi
  done

  return 1
}

function command_base() {
  local cmd="$1"

  cmd="${cmd%%[[:space:]]*}"
  printf '%s\n' "$cmd"
}

function run_command_on_file() {
  local cmd="$1"
  local file="$2"
  local base

  base="$(command_base "$cmd")"
  command_exists "$base" || die "command not found: $base"

  if [[ "$cmd" == *[[:space:]]* ]]; then
    bash -lc "$cmd \"\$1\"" _ "$file"
  else
    "$cmd" "$file"
  fi
}

function choose_editor() {
  if [[ -n "$EDITOR_CMD" ]]; then
    printf '%s\n' "$EDITOR_CMD"
    return 0
  fi

  if [[ -n "${EDITOR:-}" ]]; then
    printf '%s\n' "$EDITOR"
    return 0
  fi

  first_existing_command \
    nvim vim code subl subl4 subl3 subl2 subl1 \
    sublime_text micro nano vi || return 1
}

# -----------------------------------------------------------------------------
# Clipboard and backup helpers
# -----------------------------------------------------------------------------
function read_clipboard() {
  if command_exists wl-paste; then
    wl-paste
  elif command_exists xclip; then
    xclip -selection clipboard -out
  elif command_exists xsel; then
    xsel --clipboard --output
  elif command_exists pbpaste; then
    pbpaste
  elif command_exists powershell.exe; then
    powershell.exe -NoProfile -Command 'Get-Clipboard'
  else
    die 'no clipboard reader found: install wl-clipboard, xclip, or xsel'
  fi
}

function backup_existing_file() {
  local file="$1"
  local stamp date_part safe_name backup_dir backup_path

  [[ -e "$file" || -L "$file" ]] || return 0
  [[ -f "$file" || -L "$file" ]] || die "not a regular file: $file"

  date_part="$(date +%F)"
  stamp="$(date +%Y%m%d-%H%M%S-%N)"
  backup_dir="${LOG_ROOT}/${date_part}"
  mkdir -p -- "$backup_dir"

  safe_name="$file"
  safe_name="${safe_name/#$HOME/~}"
  safe_name="${safe_name//\//__}"
  safe_name="${safe_name// /_}"

  backup_path="${backup_dir}/${stamp}_${safe_name}.bak"
  cp -p -- "$file" "$backup_path"
  printf '%s\n' "$backup_path"
}

function paste_clipboard_into_file() {
  local file="$1"
  local tmp

  tmp="$(mktemp)"
  trap 'rm -f -- "$tmp"' RETURN
  read_clipboard >"$tmp"
  cat -- "$tmp" >"$file"
  rm -f -- "$tmp"
  trap - RETURN
}

function dump_file() {
  local viewer="$1"
  local file="$2"
  local lower_viewer

  lower_viewer="$(lower "$viewer")"

  case "$lower_viewer" in
    cat)
      cat -- "$file"
      ;;
    bat)
      if command_exists bat; then
        bat \
          --style="grid,header,snip" \
          --italic-text="always" \
          --theme="gruvbox-dark" \
          --squeeze-blank \
          --squeeze-limit="2" \
          --force-colorization \
          --terminal-width="-1" \
          --tabs="2" \
          --paging="never" \
          --chop-long-lines \
          -- "$file"
      else
        info 'bat not found; falling back to cat'
        cat -- "$file"
      fi
      ;;
    *)
      run_command_on_file "$viewer" "$file"
      ;;
  esac
}

function prompt_existing_file_action() {
  local file="$1"
  local reply

  [[ -t 0 && -t 1 ]] || {
    printf 'edit\n'
    return 0
  }

  printf 'File already exists: %s\n' "$file" >&2
  printf '[e]dit existing, [b]lank then edit, [t]ouch only, [a]bort? ' >&2
  read -r reply
  reply="$(lower "${reply:-e}")"

  case "$reply" in
    e|edit)
      printf 'edit\n'
      ;;
    b|blank|replace)
      printf 'blank\n'
      ;;
    t|touch|touch-only|no-edit)
      printf 'touch\n'
      ;;
    a|abort|q|quit)
      printf 'abort\n'
      ;;
    *)
      die "invalid choice: $reply"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
EDITOR_CMD=""
TARGET=""
DUMP_VIEWER="cat"
DO_EDIT="true"
DO_DUMP="false"
DO_PASTE="false"
DO_BLANK="false"
VERBOSE="false"

while (($#)); do
  raw="$1"
  opt="$(lower "$raw")"

  case "$opt" in
    -h|--help)
      usage
      exit 0
      ;;
    -e|--editor)
      shift
      (($#)) || die "$raw requires an editor command"
      EDITOR_CMD="$1"
      ;;
    --editor=*)
      EDITOR_CMD="${raw#*=}"
      [[ -n "$EDITOR_CMD" ]] || die "$raw requires a non-empty value"
      ;;
    -n|--no-edit)
      DO_EDIT="false"
      ;;
    -p|--paste|--paste-clipboard)
      DO_PASTE="true"
      ;;
    -d|--dump-output|--print|--view)
      DO_DUMP="true"
      DO_EDIT="false"

      if (($# >= 2)); then
        next_opt="$(lower "$2")"
        case "$next_opt" in
          cat|bat)
            DUMP_VIEWER="$2"
            shift
            ;;
        esac
      fi
      ;;
    --dump-output=*|--print=*|--view=*)
      DO_DUMP="true"
      DO_EDIT="false"
      DUMP_VIEWER="${raw#*=}"
      [[ -n "$DUMP_VIEWER" ]] || die "$raw requires a non-empty value"
      ;;
    -r|--replace|-b|--blank|--edit-empty|--edit-blank)
      DO_BLANK="true"
      ;;
    -v|--verbose)
      VERBOSE="true"
      ;;
    --)
      shift
      (($#)) || die 'missing file after --'
      [[ -z "$TARGET" ]] || die "multiple files supplied: $TARGET and $1"
      TARGET="$1"
      ;;
    -*)
      die "unknown option: $raw"
      ;;
    *)
      [[ -z "$TARGET" ]] || die "multiple files supplied: $TARGET and $raw"
      TARGET="$raw"
      ;;
  esac

  shift || true
done

[[ -n "$TARGET" ]] || die 'missing file path'

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
TARGET="$(expand_leading_tilde "$TARGET")"
PARENT_DIR="$(dirname -- "$TARGET")"
CREATED_DIR="false"
CREATED_FILE="false"
EXISTED_BEFORE="false"
BACKUP_PATH=""
ACTION=""
EDITOR_RESOLVED=""

if [[ -d "$TARGET" ]]; then
  die "target is a directory, not a file: $TARGET"
fi

if [[ ! -d "$PARENT_DIR" ]]; then
  mkdir -p -- "$PARENT_DIR"
  CREATED_DIR="true"
fi

if [[ -e "$TARGET" || -L "$TARGET" ]]; then
  EXISTED_BEFORE="true"
  BACKUP_PATH="$(backup_existing_file "$TARGET")"
else
  : >"$TARGET"
  CREATED_FILE="true"
fi

if [[ "$EXISTED_BEFORE" == "true" && \
      "$DO_BLANK" == "false" && \
      "$DO_PASTE" == "false" && \
      "$DO_EDIT" == "true" && \
      "$DO_DUMP" == "false" ]]; then
  ACTION="$(prompt_existing_file_action "$TARGET")"

  case "$ACTION" in
    edit)
      ;;
    blank)
      DO_BLANK="true"
      ;;
    touch)
      DO_EDIT="false"
      ;;
    abort)
      info "backup was already written: $BACKUP_PATH"
      exit 0
      ;;
  esac
fi

if [[ "$DO_BLANK" == "true" ]]; then
  : >"$TARGET"
fi

if [[ "$DO_PASTE" == "true" ]]; then
  paste_clipboard_into_file "$TARGET"
fi

touch -- "$TARGET"

if [[ "$VERBOSE" == "true" ]]; then
  info "target: $TARGET"
  info "parent directory: $PARENT_DIR"
  info "created parent directory: $CREATED_DIR"
  info "file existed before run: $EXISTED_BEFORE"
  info "created file: $CREATED_FILE"
  [[ -n "$BACKUP_PATH" ]] && info "backup: $BACKUP_PATH"
  info "blanked file: $DO_BLANK"
  info "pasted clipboard: $DO_PASTE"
  info "edit after create/update: $DO_EDIT"
  info "dump output: $DO_DUMP"
fi

if [[ "$DO_EDIT" == "true" ]]; then
  EDITOR_RESOLVED="$(choose_editor)" || {
    die 'no editor found; set $EDITOR or pass -e nvim, -e vim, etc.'
  }

  info "editor: $EDITOR_RESOLVED"
  run_command_on_file "$EDITOR_RESOLVED" "$TARGET"
fi

if [[ "$DO_DUMP" == "true" ]]; then
  info "viewer: $DUMP_VIEWER"
  dump_file "$DUMP_VIEWER" "$TARGET"
fi
