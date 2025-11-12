#!/usr/bin/env bash
#
# batwrap: A wrapper around 'bat' that supports custom arguments and fd-based 
# file filtering, and now explicitly supports passing extra options to the pager.
#
# ----------------------------------------------------------------------------
# Default Configuration
# ----------------------------------------------------------------------------
PAGING="never"            # --paging (change to "always" to force pager)
THEME="TwoDark"           # --theme
STYLE="grid,header"       # --style
DECORATIONS="always"      # --decorations
COLOR="always"            # --color
WRAP="auto"               # --wrap
LANGUAGE=""               # --language (empty => let bat auto-detect)
EXTENSIONS=""             # Default: no extension filtering
RECURSIVE="false"         # Recursive search
MAX_DEPTH=3               # Default max-depth for recursive searches

# This array will hold target file/directory paths.
TARGETS=()

# This array holds unrecognized arguments that we pass directly to 'bat'
PASSTHROUGH_ARGS=()

# NEW: This array will hold extra pager options specified with -P/--pager-args.
PAGER_ARGS=()

# ----------------------------------------------------------------------------
# Helper Functions
# ----------------------------------------------------------------------------

# Check if 'fd' is installed; if not, warn and use fallback file listing.
check_fd_installed() {
  if ! command -v fd >/dev/null 2>&1; then
    echo "Warning: 'fd' is not installed. Falling back to basic file listing." >&2
    echo "To enable optimized searching with 'fd', install it using your package manager." >&2
    return 1
  fi
  return 0
}

# Display usage instructions
usage() {
  cat <<EOF | bat --style="grid,header" --paging="never" --color="always" --language="LESS" --theme-light="Dracula"
Usage: $(basename "$0") [OPTIONS] -t <TARGETS...>

A wrapper script for 'bat' with optional fd-based file filtering.
It now supports passing extra options to the pager with -P/--pager-args.
(Note: If you supply pager arguments, consider using -p always to enable paging.)

Options:
  -t, --target <TARGETS...>          Target paths (comma- or space-separated).
  -r, --recursive [MAX_DEPTH]        Recursively display files (default depth: $MAX_DEPTH).
  -x, --extensions <EXTS...>         Comma- or space-separated list of extensions to include.
                                     e.g., -x "py,sh,md" or -x py sh
                                     Defaults to all files if not specified.
  -p, --paging [never|auto|always]   Set paging mode (default: $PAGING).
  --theme <THEME>                    Set the theme (default: $THEME).
  -s, --style <STYLE>                Style (default: $STYLE).
  -d, --decorations <WHEN>           Decorations (default: $DECORATIONS).
  -c, --color <WHEN>                 Color mode (default: $COLOR).
  -w, --wrap <MODE>                  Wrapping mode (default: $WRAP).
  -l, --language <LANG>              Force a language (if not set, let bat auto-detect).
  -P, --pager-args <ARG>             Pass an extra argument to the pager (e.g., less).
                                     This option can be used multiple times.
  Any unknown arguments (not recognized above) will be passed directly to 'bat'.

Examples:
  # Default: Display all files in ~/repos
  $(basename "$0") -t ~/repos

  # Recursive search with extension filtering
  $(basename "$0") -t ~/repos -r 3 -x "py,md,sh"

  # Target a single file with extra pager options (note: use -p always)
  $(basename "$0") -t backup_script.sh -p always -P --chop-long-lines -P --squeeze-blank

  # Force language for highlighting
  $(basename "$0") -t ~/repos -l bash
EOF
}

# Check if a file is binary, so we can skip it.
is_binary() {
  file --mime-encoding "$1" 2>/dev/null | grep -q "binary"
}

# ----------------------------------------------------------------------------
# Parse Command-Line Arguments
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)
      ARG_VALUE=$(echo "$2" | sed 's/,/ /g')
      for entry in $ARG_VALUE; do
        TARGETS+=("$entry")
      done
      shift 2
      ;;
    -r|--recursive)
      RECURSIVE="true"
      if [[ $# -gt 1 && "$2" =~ ^[0-9]+$ ]]; then
        MAX_DEPTH="$2"
        shift 2
      else
        shift
      fi
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
    -P|--pager-args)
      # NEW: Collect extra pager options.
      if [[ -z "$2" ]]; then
        echo "Error: --pager-args requires an argument" >&2
        exit 1
      fi
      PAGER_ARGS+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      # If a double dash is encountered, break and pass any remaining args as passthrough.
      shift
      while [[ $# -gt 0 ]]; do
        PASSTHROUGH_ARGS+=("$1")
        shift
      done
      ;;
    *)
      # Forward any unrecognized arguments to 'bat'
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
  esac
done

# Ensure at least one target is provided.
if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  echo "No targets specified."
  read -n 1 -r -p "Show help? [Y/n] " ans
  echo
  ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
  if [[ "$ans" == "y" ]]; then
    usage
  fi
  exit 1
fi
THEME="Monokai Extended Bright"
# ----------------------------------------------------------------------------
# Build Bat Command
# ----------------------------------------------------------------------------
BAT_CMD=("bat")
BAT_CMD+=( "--paging=$PAGING" )
BAT_CMD+=( "--style=$STYLE" )
BAT_CMD+=( "--decorations=$DECORATIONS" )
BAT_CMD+=( "--color=$COLOR" )
BAT_CMD+=( "--wrap=$WRAP" )
[[ -n "$THEME" ]] && BAT_CMD+=( "--theme=$THEME" )
[[ -n "$LANGUAGE" ]] && BAT_CMD+=( "--language=$LANGUAGE" )

# Append any passthrough arguments that were not explicitly recognized.
BAT_CMD+=( "${PASSTHROUGH_ARGS[@]}" )

# NEW: If extra pager arguments were provided, add a --pager option.
if [ ${#PAGER_ARGS[@]} -gt 0 ]; then
  # Join all pager arguments with a space. This creates a single string.
  PAGER_STRING="${PAGER_ARGS[*]}"
  # Append the constructed pager command.
  BAT_CMD+=( "--pager=less $PAGER_STRING" )
fi

# ----------------------------------------------------------------------------
# Process Targets
# ----------------------------------------------------------------------------
process_target() {
  local TGT="$1"

  if [[ -f "$TGT" ]]; then
    # Process single file.
    if is_binary "$TGT"; then
      echo "Skipping binary file: $TGT" >&2
    else
      "${BAT_CMD[@]}" "$TGT"
    fi
  elif [[ -d "$TGT" ]]; then
    # Process directory: use fd if available.
    if check_fd_installed; then
      FD_CMD=("fd" "--type" "f" "--search-path" "$TGT")
      [[ "$RECURSIVE" == "true" ]] && FD_CMD+=( "--max-depth" "$MAX_DEPTH" )
      if [[ -n "$EXTENSIONS" ]]; then
        for ext in $EXTENSIONS; do
          FD_CMD+=( "-e" "$ext" )
        done
      fi
      "${FD_CMD[@]}" --print0 2>/dev/null | while IFS= read -r -d $'\0' file; do
        if is_binary "$file"; then
          echo "Skipping binary file: $file" >&2
        else
          "${BAT_CMD[@]}" "$file"
        fi
      done
    else
      # Fallback using find if fd is not installed.
      if [[ "$RECURSIVE" == "true" ]]; then
        find "$TGT" -maxdepth "$MAX_DEPTH" -type f -print0 2>/dev/null |
          while IFS= read -r -d $'\0' file; do
            if is_binary "$file"; then
              echo "Skipping binary file: $file" >&2
            else
              "${BAT_CMD[@]}" "$file"
            fi
          done
      else
        for file in "$TGT"/*; do
          if [[ -f "$file" ]] && ! is_binary "$file"; then
            "${BAT_CMD[@]}" "$file"
          fi
        done
      fi
    fi
  else
    echo "Warning: '$TGT' is not a valid file or directory." >&2
  fi
}

for TGT in "${TARGETS[@]}"; do
  process_target "$TGT"
done
