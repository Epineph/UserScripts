#!/usr/bin/env bash
#
# A script combining fzf, fd, and bat to preview and select files for editing.

###############################################################################
# Default Configuration
###############################################################################
EDITOR="vim"              # Default editor
PAGING="never"            # bat --paging
STYLE="grid,header"       # bat --style
THEME="Dracula"           # bat --theme
COLOR="always"            # bat --color
WRAP="wrap"               # fzf preview window
LANGUAGE=""               # Optional bat --language (auto-detect if empty)
MAX_DEPTH=""              # Default max depth for recursive searches (unlimited)
EXTENSIONS=""             # Default: no filtering
OUTPUT_ONLY=false          # Output file content with bat (mutually exclusive with edit)

# Will hold the target paths
TARGETS=()

###############################################################################
# Helper Functions
###############################################################################

# Display usage instructions
usage() {
  bat --style="grid,header" --paging="never" --color="always" --language="LESS" --theme="Dracula" <<EOF
Usage: $(basename "$0") [OPTIONS] -t <TARGETS...>

A script combining fzf, fd, and bat to preview and select files for editing.

Options:
  -t, --target <TARGETS...>          Target file(s) or folder(s) (comma- or space-separated).
  -e, --editor <EDITOR>              Specify editor (default: vim).
  -r, --recursive [N]                Enable recursive search with optional max depth N (default: unlimited).
  -x, --extensions <EXTS...>         Comma- or space-separated list of extensions to include.
                                     e.g., -x "py,sh,md".
  -o, --output                       Output file content with bat instead of editing.
  -p, --paging [never|auto|always]   Set bat paging mode (default: $PAGING).
  --theme <THEME>                    Set bat theme (default: $THEME).
  -l, --language <LANG>              Force bat language for syntax highlighting.
  -h, --help                         Show this help message and exit.

Examples:
  # Target a single file
  $(basename "$0") -t ~/myfile.sh -e nano

  # Target a folder with recursive search and filtering
  $(basename "$0") -t ~/projects -x "py,sh" -e nvim

  # Recursive search with depth
  $(basename "$0") -t ~/projects -r 2

  # Output file content with bat
  $(basename "$0") -t ~/myfile.sh -o
EOF
}

# Check if fd is installed
check_fd_installed() {
  if ! command -v fd >/dev/null 2>&1; then
    fd_documentation
    return 1
  fi
  return 0
}

# Documentation for fd
fd_documentation() {
  bat --style="grid,header" --paging="never" --color="always" --language="LESS" --theme="Dracula" <<EOF
fd is a fast and user-friendly alternative to find.

To install fd:
  - On Arch-based systems: sudo pacman -S fd
  - On Debian-based systems: sudo apt install fd-find
  - On macOS: brew install fd
EOF
}

# Check if fzf is installed
check_fzf_installed() {
  if ! command -v fzf >/dev/null 2>&1; then
    fzf_documentation
    return 1
  fi
  return 0
}

# Documentation for fzf
fzf_documentation() {
  bat --style="grid,header" --paging="never" --color="always" --language="LESS" --theme="Dracula" <<EOF
fzf is a command-line fuzzy finder.

To install fzf:
  - On Arch-based systems: sudo pacman -S fzf
  - On Debian-based systems: sudo apt install fzf
  - On macOS: brew install fzf
EOF
}

###############################################################################
# Parse Command-Line Arguments
###############################################################################

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)
      ARG_VALUE=$(echo "$2" | sed 's/,/ /g')
      for entry in $ARG_VALUE; do
        TARGETS+=("$entry")
      done
      shift 2
      ;;
    -e|--editor)
      EDITOR="$2"
      shift 2
      ;;
    -r|--recursive)
      if [[ "$2" =~ ^[0-9]+$ ]]; then
        MAX_DEPTH="$2"
        shift 2
      else
        MAX_DEPTH=""
        shift
      fi
      ;;
    -x|--extensions)
      EXTENSIONS=$(echo "$2" | sed 's/,/ /g')
      shift 2
      ;;
    -o|--output)
      OUTPUT_ONLY=true
      shift
      ;;
    -p|--paging)
      PAGING="$2"
      shift 2
      ;;
    --theme)
      THEME="$2"
      shift 2
      ;;
    -l|--language)
      LANGUAGE="$2"
      shift 2
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

# Check for fzf and exit if not installed
if ! check_fzf_installed; then
  echo "fzf is required for this script to run."
  exit 1
fi

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
# Bat and Fzf Configuration
###############################################################################
BAT_CMD=("bat" "--paging=$PAGING" "--theme=$THEME" "--color=$COLOR" "--style=$STYLE")
[[ -n "$LANGUAGE" ]] && BAT_CMD+=( "--language=$LANGUAGE" )

FZF_PREVIEW_CMD="bat ${BAT_CMD[*]} -- {}"

###############################################################################
# Process Targets
###############################################################################

for TGT in "${TARGETS[@]}"; do
  if [[ -f "$TGT" ]]; then
    # If the target is a file, either preview or open it
    echo "Target is a file: $TGT"
    if file --mime-encoding "$TGT" | grep -q "binary"; then
      echo "Skipping binary file: $TGT" >&2
    else
      if [[ "$OUTPUT_ONLY" == true ]]; then
        bat --style="$STYLE" --color="$COLOR" --theme="$THEME" "$TGT"
      else
        echo "$TGT" | fzf --preview="$FZF_PREVIEW_CMD" --preview-window=right:60%:$WRAP
        $EDITOR "$TGT"
      fi
    fi
  elif [[ -d "$TGT" ]]; then
    # If the target is a folder, search recursively and preview
    echo "Target is a folder: $TGT"
    if check_fd_installed; then
      FD_CMD=("fd" "--type" "f" "--search-path" "$TGT")
      [[ -n "$MAX_DEPTH" ]] && FD_CMD+=("--max-depth" "$MAX_DEPTH")
      [[ -n "$EXTENSIONS" ]] && for ext in $EXTENSIONS; do FD_CMD+=("-e" "$ext"); done

      FILE=$( "${FD_CMD[@]}" | fzf --preview="$FZF_PREVIEW_CMD" --preview-window=right:60%:$WRAP )
      if [[ -n "$FILE" ]]; then
        if [[ "$OUTPUT_ONLY" == true ]]; then
          bat --style="$STYLE" --color="$COLOR" --theme="$THEME" --paging=never "$FILE"
        else
          $EDITOR "$FILE"
        fi
      fi
    else
      # Fallback to find
      FIND_CMD=("find" "$TGT" -type f)
      [[ -n "$MAX_DEPTH" ]] && FIND_CMD+=("-maxdepth" "$MAX_DEPTH")
      FILE=$( "${FIND_CMD[@]}" | fzf --preview="$FZF_PREVIEW_CMD" --preview-window=right:60%:$WRAP )
      if [[ -n "$FILE" ]]; then
        if [[ "$OUTPUT_ONLY" == true ]]; then
          bat --style="$STYLE" --color="$COLOR" --theme="$THEME" "$FILE"
        else
          $EDITOR "$FILE"
        fi
      fi
    fi
  else
    echo "Warning: '$TGT' is not a valid file or directory." >&2
  fi
done

