#!/usr/bin/env zsh
# ------------------------------------------------------------------------------
# Script: batview
# Purpose: Display a file using 'bat' with your preferred defaults
# Usage: batview -t <path/to/file>
# Options:
#   -t, --target   Path to the file you wish to view (required)
#   -h, --help     Show this help message and exit
# ------------------------------------------------------------------------------
  
# ---- Help/Usage ----
usage() {
  cat <<-EOF
  batview — view files through 'bat' with preset options

  Usage:
    batview -t <file>
  
  Options:
    -t, --target   Path to the file you wish to view (required)
    -h, --help     Show this help message and exit

  Defaults passed to bat:
    --theme="gruvbox-dark"
    --style="grid,header,snip"
    --strip-ansi="auto"
    --squeeze-blank
    --squeeze-limit="2"
    --paging="never"
    --decorations="always"
    --color="always"
    --italic-text="always"
    --terminal-width="-2"
    --tabs="1"
  EOF
}

# ---- Parse arguments ----
TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)
      if [[ -n "$2" && "$2" != -* ]]; then
        TARGET=$2
        shift 2
      else
        echo "Error: --target requires a file path argument." >&2
        usage
        exit 1
      fi
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: Unrecognized option '$1'." >&2
      usage
      exit 1
      ;;
  esac
done

# ---- Ensure target was provided ----
if [[ -z "$TARGET" ]]; then
  echo "Error: No target file specified." >&2
  usage
  exit 1
fi

# ---- Check that the file exists ----
if [[ ! -e "$TARGET" ]]; then
  echo "Error: File '$TARGET' does not exist." >&2
  exit 1
fi

# ---- Execute bat with your defaults ----
exec bat \
  --theme="gruvbox-dark" \
  --style="grid,header,snip" \
  --strip-ansi="auto" \
  --squeeze-blank \
  --squeeze-limit="2" \
  --paging="never" \
  --decorations="always" \
  --color="always" \
  --italic-text="always" \
  --terminal-width="-2" \
  --tabs="1" \
  -- "$TARGET"

