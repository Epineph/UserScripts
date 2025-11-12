#!/usr/bin/env bash
###############################################################################
#  batwrap.sh
#
#  Purpose  : Provide a convenient front-end to `bat` that bakes-in your
#             preferred defaults and reads the file to inspect from
#             -t | --target.
#
#  Usage    :  batwrap.sh -t <path/to/file>
#              batwrap.sh --target <path/to/file>
#              batwrap.sh -h | --help
#
#  Exit codes:
#     0  – success
#     1  – user error (missing option, unknown flag, etc.)
#     2  – underlying `bat` not found
#
#  Author   : <your-name-or-initials>
#  Created  : 2025-05-14
#  License  : MIT (or as you prefer)
###############################################################################

set -euo pipefail

############################################################
# CONSTANTS
############################################################
# Default bat options, kept in a single, readable array.
BAT_OPTS=(
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
)

############################################################
# FUNCTIONS
############################################################
show_help() {
  cat <<'EOF'
batwrap.sh – display a file with bat using fixed defaults

SYNOPSIS
  batwrap.sh -t <file>
  batwrap.sh --target <file>
  batwrap.sh -h | --help

DESCRIPTION
  Wraps the bat command with the following immutable defaults:

    --theme="gruvbox-dark"
    --style="grid,header,snip"
    --strip-ansi="auto"
    --squeeze-blank --squeeze-limit="2"
    --paging="never"
    --decorations="always"
    --color="always"
    --italic-text="always"
    --terminal-width="-2"
    --tabs="1"

OPTIONS
  -t, --target FILE   File to display (required).
  -h, --help          Show this help and exit.

EXAMPLE
  batwrap.sh -t /etc/mkinitcpio.conf
EOF
}

error() { printf 'Error: %s\n' "$1" >&2; exit 1; }

############################################################
# PREREQUISITE CHECK
############################################################
if ! command -v bat >/dev/null 2>&1; then
  error "bat is not installed or not in PATH." && exit 2
fi

############################################################
# ARGUMENT PARSING
############################################################
TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--target)
      [ $# -lt 2 ] && error "Option '$1' requires an argument."
      TARGET=$2
      shift 2
      ;;
    -l|-L|--lines|--line-numbers)
      for i in "${!BAT_OPTS[@]}"; do
        if [[ ${BAT_OPTS[$i]} == --style=* ]]; then
          BAT_OPTS[$i]="${BAT_OPTS[$i]},numbers"
          break
        fi
      done
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      error "Unknown option $1"
      ;;
    *)
      error "Unexpected argument: $1"
      ;;
  esac
done


[ -z "$TARGET" ] && error "No target file supplied. Use -t|--target <file>."

############################################################
# MAIN EXECUTION
############################################################
# shellcheck disable=SC2086
bat "${BAT_OPTS[@]}" "$TARGET"


