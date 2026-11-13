#!/usr/bin/env bash
#===============================================================================
#
# FILE: bathelp
#
# DESCRIPTION:
#   Wrap any command’s “--help” output through bat(1) with a consistent style.
#
# INSTALLATION:
#   Place this file in your PATH (e.g. ~/bin/bathelp) and make it executable:
#     chmod +x ~/bin/bathelp
#
# USAGE:
#   bathelp [OPTIONS] <command> [-- args...]
#
# OPTIONS:
#   -t, --theme   THEME       bat theme (default: Monokai Extended Bright)
#   -s, --style   STYLE       bat style (comma-separated; default: grid,header-filename,snip,snip)
#   -p, --pager   PAGER       pager program (default: less)
#   -T, --tabs    N           number of spaces per tab (default: 2)
#   -w, --wrap    MODE        wrap mode: auto|character|never (default: auto)
#   -h, --help                display this help and exit
#
# EXAMPLES:
#   bathelp git
#   bathelp -t Dracula make -- -j8
#
#===============================================================================

set -eu
print_usage() {
  sed -n '1,50p' "$0" | sed 's/^#\s\?//'
  exit 0
}

# --- Defaults ---------------------------------------------------------------
THEME="Monokai Extended Bright"
STYLE="grid,header-filename,snip,snip"
PAGER="less"
TABS="2"
WRAP="auto"

# --- Parse options ---------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--theme)    THEME="$2"; shift 2;;
    -s|--style)    STYLE="$2"; shift 2;;
    -p|--pager)    PAGER="$2"; shift 2;;
    -T|--tabs)     TABS="$2"; shift 2;;
    -w|--wrap)     WRAP="$2"; shift 2;;
    -h|--help)     print_usage;;
    --)            shift; break;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *) break;;
  esac
done

if [[ $# -lt 1 ]]; then
  echo "Error: Missing <command>" >&2
  print_usage
fi

COMMAND="$1"; shift

# --- Main ------------------------------------------------------------------
# Run the command with “--help” (plus any extra args), pipe through bat
"$COMMAND" "$@" --help 2>&1 |
  bat \
    --language=help \
    --paging=never \
    --pager="$PAGER" \
    --theme="$THEME" \
    --chop-long-lines \
    --squeeze-blank \
    --tabs="$TABS" \
    --wrap="$WRAP" \
    --binary="as-text" \
    --nonprintable-notation="caret" \
    --italic-text="always" \
    --style="$STYLE"

