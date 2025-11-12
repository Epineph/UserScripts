#!/usr/bin/env bash
#
# A script combining fzf, fd, and bat to preview and select files for editing.
#

###############################################################################
# Default Configuration
###############################################################################
# Use the environment variable EDITOR if it is defined; otherwise, default to "vim".
EDITOR="${EDITOR:-nvim}"              # Default editor (can be overridden via -e/--editor)

# Other script defaults
PAGING="never"                        # bat --paging option
THEME="Monokai Extended Bright"       # Default theme (aligned with your zsh view function)
COLOR="always"                        # bat --color option
WRAP="wrap"                           # fzf preview window setting
LANGUAGE=""                           # Optional bat --language (auto-detect if empty)

# fzf/FD related defaults
RECURSIVE="true"          # Recursive search by default
MAX_DEPTH=3               # Default maximum depth for recursive search
EXTENSIONS=""             # No extension filtering by default

# Array to hold specified target paths (files or directories)
TARGETS=()

###############################################################################
# Define Bat/Cat Printer Variable
###############################################################################
# Check if bat is installed. If so, define BAT_PRINT and BAT_CMD arrays
# with your preferred options; otherwise, fall back to using cat.
if command -v bat &>/dev/null; then
  # BAT_PRINT will be used for displaying documentation/help messages.
  BAT_PRINT=(bat --set-terminal-title --style="grid,header,snip" --squeeze-blank --pager="less" \
             --decorations="always" --italic-text="always" --color="always" --chop-long-lines \
             --tabs=2 --wrap="auto" --paging="never" --strip-ansi="always" --language="LESS" \
             --theme="$THEME")
  # BAT_CMD is used specifically for the fzf preview command.
  BAT_CMD=(bat --set-terminal-title --style="grid,header,snip" --squeeze-blank --pager="less" \
    --decorations="always" --italic-text="always" --color="always" --terminal-width="-1" \
           --tabs=2 --wrap="auto" --paging="never" --strip-ansi="always" --theme="$THEME")
  # Append language option if one is provided later.
  [[ -n "$LANGUAGE" ]] && BAT_CMD+=( "--language=$LANGUAGE" )
else
  # Fallback: if bat is not installed, both the printer and the preview commands will use cat.
  BAT_PRINT=(cat)
  BAT_CMD=(cat)
fi

###############################################################################
# Helper Functions
###############################################################################

# Display usage instructions.
usage() {
  "${BAT_PRINT[@]}" <<EOF
Usage: $(basename "$0") [OPTIONS] -t <TARGETS...>

A script combining fzf, fd, and bat to preview and select files for editing.

Options:
  -t, --target <TARGETS...>          Target file(s) or folder(s) (comma- or space-separated).
  -e, --editor <EDITOR>              Specify editor to open file (default: uses \$EDITOR env variable or vim).
  -r, --recursive                    Enable recursive search in folders (default: true).
  -x, --extensions <EXTS...>         Comma- or space-separated list of extensions to include.
                                     e.g., -x "py,sh,md".
  -p, --paging [never|auto|always]   Set bat paging mode (default: $PAGING).
  --theme <THEME>                    Set bat theme (default: $THEME).
  -l, --language <LANG>              Force bat language for syntax highlighting.
  -h, --help                         Show this help message and exit.

Examples:
  # Target a single file and open with nano
  $(basename "$0") -t ~/myfile.sh -e nano

  # Target a folder with recursive search and filtering; open file with nvim
  $(basename "$0") -t ~/projects -x "py,sh" -e nvim
EOF
}

# Documentation for fd.
fd_documentation() {
  "${BAT_PRINT[@]}" <<EOF
fd is a fast and user-friendly alternative to find.

To install fd:
  - On Arch-based systems: sudo pacman -S fd
  - On Debian-based systems: sudo apt install fd-find
  - On macOS: brew install fd
EOF
}

# Documentation for fzf.
fzf_documentation() {
  "${BAT_PRINT[@]}" <<EOF
fzf is a command-line fuzzy finder.

To install fzf:
  - On Arch-based systems: sudo pacman -S fzf
  - On Debian-based systems: sudo apt install fzf
  - On macOS: brew install fzf
EOF
}

# Check if fd is installed.
check_fd_installed() {
  if ! command -v fd >/dev/null 2>&1; then
    fd_documentation
    return 1
  fi
  return 0
}

# Check if fzf is installed.
check_fzf_installed() {
  if ! command -v fzf >/dev/null 2>&1; then
    fzf_documentation
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
      # Allow multiple targets passed as comma- or space-separated values.
      ARG_VALUE=$(echo "$2" | sed 's/,/ /g')
      for entry in $ARG_VALUE; do
        TARGETS+=("$entry")
      done
      shift 2
      ;;
    -e|--editor)
      # Override the default editor via the command-line option.
      EDITOR="$2"
      shift 2
      ;;
    -r|--recursive)
      RECURSIVE="true"
      shift
      ;;
    -x|--extensions)
      EXTENSIONS=$(echo "$2" | sed 's/,/ /g')
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

# Ensure that fzf is installed.
if ! check_fzf_installed; then
  echo "fzf is required for this script to run."
  exit 1
fi

# Ensure at least one target is provided.
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
# FZF Preview Command Construction
###############################################################################
# Construct the preview command using BAT_CMD. In the fallback scenario,
# this will simply be "cat" (without syntax highlighting) since bat is not installed.
FZF_PREVIEW_CMD="${BAT_CMD[*]} -- {}"

###############################################################################
# Process Targets
###############################################################################
for TGT in "${TARGETS[@]}"; do
  if [[ -f "$TGT" ]]; then
    # Target is a file: preview and then open it.
    echo "Target is a file: $TGT"
    if file --mime-encoding "$TGT" | grep -q "binary"; then
      echo "Skipping binary file: $TGT" >&2
    else
      echo "$TGT" | fzf --preview="$FZF_PREVIEW_CMD" --preview-window=right:60%:$WRAP
      $EDITOR "$TGT"
    fi
  elif [[ -d "$TGT" ]]; then
    # Target is a directory: search recursively and allow file selection.
    echo "Target is a folder: $TGT"
    if check_fd_installed; then
      FD_CMD=(fd --type f --search-path "$TGT")
      if [[ "$RECURSIVE" == "true" ]]; then
        FD_CMD+=( --max-depth "$MAX_DEPTH" )
      fi
      [[ -n "$EXTENSIONS" ]] && for ext in $EXTENSIONS; do FD_CMD+=( -e "$ext" ); done

      FILE=$( "${FD_CMD[@]}" | fzf --preview="$FZF_PREVIEW_CMD" --preview-window=right:60%:$WRAP )
      [[ -n "$FILE" ]] && $EDITOR "$FILE"
    else
      # Fallback to using 'find' if fd is not available.
      FILE=$(find "$TGT" -type f | fzf --preview="$FZF_PREVIEW_CMD" --preview-window=right:60%:$WRAP)
      [[ -n "$FILE" ]] && $EDITOR "$FILE"
    fi
  else
    echo "Warning: '$TGT' is not a valid file or directory." >&2
  fi
done

