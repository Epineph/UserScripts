#!/usr/bin/env bash

# Default Configuration
EDITOR="vim"
BAT_DEFAULTS=(
  "--paging=never"
  "--theme=Dracula"
  "--color=always"
  "--style=grid,header"
)
FZF_PREVIEW_WINDOW="right:60%:wrap"
RECURSIVE="true"
MAX_DEPTH=3
EXTENSIONS=""
BAT_EXTRA_ARGS=()
TARGETS=()

# Helper Functions
usage() {
  bat --style="grid,header" --paging="never" --color="always" --language="LESS" --theme="Dracula" <<EOF
Usage: $(basename "$0") [OPTIONS] -t <TARGETS...> -- [BAT OPTIONS]

A script combining fzf, fd, and bat to preview and select files for editing.

Options:
  -t, --target <TARGETS...>          Target file(s) or folder(s).
  -e, --editor <EDITOR>              Specify editor (default: vim).
  -x, --extensions <EXTS...>         Filter by file extensions.
  --                                 Pass additional options to bat.

Examples:
  $(basename "$0") -t ~/repos -- --squeeze-blank
EOF
}

check_fd_installed() { command -v fd >/dev/null 2>&1 || return 1; }
check_fzf_installed() { command -v fzf >/dev/null 2>&1 || return 1; }

# Parse Arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)
      IFS=',' read -ra ADDR <<<"$2"
      TARGETS+=("${ADDR[@]}")
      shift 2
      ;;
    -e|--editor)
      EDITOR="$2"
      shift 2
      ;;
    -x|--extensions)
      EXTENSIONS=("${2//,/ }")
      shift 2
      ;;
    --)
      shift
      BAT_EXTRA_ARGS+=("$@")
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Check Dependencies
if ! check_fzf_installed; then
  echo "fzf is required. Install it and try again."
  exit 1
fi

# Bat Command
BAT_CMD=("bat" "${BAT_DEFAULTS[@]}" "${BAT_EXTRA_ARGS[@]}")

# FZF Preview Command
FZF_PREVIEW_CMD="[[ -f '{}' ]] && bat ${BAT_CMD[*]} -- '{}' || echo 'File not found or inaccessible: {}'"

# Process Targets
for TGT in "${TARGETS[@]}"; do
  if [[ -d "$TGT" ]]; then
    if check_fd_installed; then
      FD_CMD=("fd" "--type" "f" "--search-path" "$TGT")
      [[ -n "$EXTENSIONS" ]] && for ext in $EXTENSIONS; do FD_CMD+=("-e" "$ext"); done
      FILE=$( "${FD_CMD[@]}" | fzf --preview="$FZF_PREVIEW_CMD" --preview-window="$FZF_PREVIEW_WINDOW" )
    else
      FILE=$(find "$TGT" -type f | fzf --preview="$FZF_PREVIEW_CMD" --preview-window="$FZF_PREVIEW_WINDOW")
    fi
    [[ -n "$FILE" ]] && $EDITOR "$FILE"
  elif [[ -f "$TGT" ]]; then
    echo "$TGT" | fzf --preview="$FZF_PREVIEW_CMD" --preview-window="$FZF_PREVIEW_WINDOW"
    $EDITOR "$TGT"
  else
    echo "Target '$TGT' is not a valid file or directory."
  fi
done

