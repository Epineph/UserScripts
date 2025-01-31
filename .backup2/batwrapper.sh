#!/usr/bin/env bash

###############################################################################
# Default Configuration
###############################################################################
PAGING="never"            # --paging
THEME="Dracula"           # --theme
STYLE="grid,header"       # --style
DECORATIONS="always"      # --decorations
COLOR="always"            # --color
WRAP="auto"               # --wrap
LANGUAGE=""               # --language (empty => let bat auto-detect)
EXTENSIONS=""             # Default: no extension filtering
RECURSIVE="false"         # Recursive search
MAX_DEPTH=3               # Default max depth for recursive searches
TARGETS=()                # Will hold target paths
BAT_EXTRA_ARGS=()         # Custom extra bat arguments

###############################################################################
# Helper Functions
###############################################################################

# Display usage instructions
usage() {
  bat --style="grid,header" --paging="never" --color="always" --language="LESS" --theme="Dracula" <<EOF
Usage: $(basename "$0") [OPTIONS] -t <TARGETS...> -- [BAT OPTIONS]

A wrapper for bat with fd integration for filtering and fzf for interactive selection.

Options:
  -t, --target <TARGETS...>          Target file(s) or folder(s) (comma- or space-separated).
  -r, --recursive                    Enable recursive search in folders (default: false).
  -x, --extensions <EXTS...>         Filter by file extensions (comma- or space-separated).
  -p, --paging [never|auto|always]   Set bat paging mode (default: $PAGING).
  --theme <THEME>                    Set bat theme (default: $THEME).
  -s, --style <STYLE>                Set bat style (default: $STYLE).
  -d, --decorations <WHEN>           Set bat decorations (default: $DECORATIONS).
  -c, --color <WHEN>                 Set bat color mode (default: $COLOR).
  -w, --wrap <MODE>                  Set bat wrapping mode (default: $WRAP).
  -l, --language <LANG>              Force bat language for syntax highlighting.
  --                                 All arguments after this are passed directly to bat.

Examples:
  # Target a single file and pass additional bat options
  $(basename "$0") -t ~/myfile.sh -- --highlight-line :40 --chop-long-lines

  # Recursive search with extension filtering and custom bat options
  $(basename "$0") -t ~/projects -r -x "py,sh" -- --tabs 4 --squeeze-blank
EOF
}

# Check if fd is installed
check_fd_installed() {
  if ! command -v fd >/dev/null 2>&1; then
    echo "Warning: 'fd' is not installed. Falling back to basic file listing." >&2
    return 1
  fi
  return 0
}

###############################################################################
# Parse Command-Line Arguments
###############################################################################

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)
      IFS=',' read -ra ADDR <<<"$2"
      TARGETS+=("${ADDR[@]}")
      shift 2
      ;;
    -r|--recursive)
      RECURSIVE="true"
      shift
      ;;
    -x|--extensions)
      EXTENSIONS=("${2//,/ }")
      shift 2
      ;;
    -p|--paging)
      PAGING="$2"
      shift 2
      ;;
    --theme)
      THEME="$2"
      shift 2
      ;;
    -s|--style)
      STYLE="$2"
      shift 2
      ;;
    -d|--decorations)
      DECORATIONS="$2"
      shift 2
      ;;
    -c|--color)
      COLOR="$2"
      shift 2
      ;;
    -w|--wrap)
      WRAP="$2"
      shift 2
      ;;
    -l|--language)
      LANGUAGE="$2"
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

# Ensure at least one target is provided
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "No targets specified."
  read -n 1 -r -p "Show help? [Y/n] " ans
  echo
  ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
  if [[ "$ans" == "y" ]]; then
    usage
  fi
  exit 1
fi

###############################################################################
# Build Bat Command
###############################################################################
BAT_CMD=("bat")
BAT_CMD+=( "--paging=$PAGING" "--theme=$THEME" "--style=$STYLE" "--decorations=$DECORATIONS" "--color=$COLOR" "--wrap=$WRAP" )
[[ -n "$LANGUAGE" ]] && BAT_CMD+=( "--language=$LANGUAGE" )
BAT_CMD+=( "${BAT_EXTRA_ARGS[@]}" )

###############################################################################
# Process Targets
###############################################################################
process_target() {
  local TGT="$1"

  if [[ -f "$TGT" ]]; then
    # If the target is a single file, process it directly
    "${BAT_CMD[@]}" "$TGT"
  elif [[ -d "$TGT" ]]; then
    # If the target is a directory, use fd or fallback to find
    if check_fd_installed; then
      FD_CMD=("fd" "--type" "f" "--search-path" "$TGT")
      [[ "$RECURSIVE" == "true" ]] && FD_CMD+=( "--max-depth" "$MAX_DEPTH" )
      [[ -n "$EXTENSIONS" ]] && for ext in $EXTENSIONS; do FD_CMD+=( "-e" "$ext" ); done

      "${FD_CMD[@]}" --print0 2>/dev/null | while IFS= read -r -d $'\0' file; do
        "${BAT_CMD[@]}" "$file"
      done
    else
      # Fallback to find if fd is not available
      find "$TGT" -type f -print0 2>/dev/null | while IFS= read -r -d $'\0' file; do
        "${BAT_CMD[@]}" "$file"
      done
    fi
  else
    echo "Warning: '$TGT' is not a valid file or directory." >&2
  fi
}

for TGT in "${TARGETS[@]}"; do
  process_target "$TGT"
done

