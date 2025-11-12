#!/usr/bin/env bash
#===============================================================================
#
# FILE: view
#
# DESCRIPTION:
#   A robust “view” wrapper: if bat is installed, use it with rich formatting;
#   otherwise fall back to plain cat(1). Supports theming, highlighting,
#   line-ranges, line numbers, custom pager, etc.
#
# INSTALLATION:
#   Place in your PATH (e.g. ~/bin/view) and make executable:
#     chmod +x ~/bin/view
#
# USAGE:
#   view [OPTIONS] <file>
#
# OPTIONS:
#   -t, --theme    THEME      bat theme (default: Dracula)
#   -s, --style    STYLE      bat style (default: header,grid)
#   -l, --highlight LINES     highlight lines (e.g. 3 or 3,5-7)
#   -r, --range    START:END  show only this line range
#   -n, --numbers              include line numbers
#   -p, --pager    PAGER      pager program (default: less)
#   -h, --help                 display this help and exit
#
# EXAMPLES:
#   view -t Solarized file.txt
#   view -r 10:20 script.sh
#
#===============================================================================

set -eu
print_usage() {
  sed -n '1,60p' "$0" | sed 's/^#\s\?//'
  exit 0
}

# --- Defaults ---------------------------------------------------------------
THEME="Dracula"
STYLE="header,grid"
HIGHLIGHT=""
RANGE=""
NUMBERS=false
PAGER="less"

# --- Parse options ---------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--theme)      THEME="$2"; shift 2;;
    -s|--style)      STYLE="$2"; shift 2;;
    -l|--highlight)  HIGHLIGHT="--highlight-line=$2"; shift 2;;
    -r|--range)      RANGE="--line-range=$2"; shift 2;;
    -n|--numbers)    NUMBERS=true; shift;;
    -p|--pager)      PAGER="$2"; shift 2;;
    -h|--help)       print_usage;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *) break;;
  esac
done

if [[ $# -ne 1 ]]; then
  echo "Usage: view [options] <file>" >&2
  exit 1
fi

FILE="$1"

# --- Main ------------------------------------------------------------------
if command -v bat &>/dev/null; then
  BAT_STYLE="$STYLE"
  $NUMBERS && BAT_STYLE+=",numbers"

  bat \
    --set-terminal-title \
    --style="$BAT_STYLE" \
    --squeeze-blank \
    --theme="$THEME" \
    --pager="$PAGER" \
    --decorations="always" \
    --italic-text="always" \
    --color="always" \
    --terminal-width="-1" \
    --tabs="2" \
    --chop-long-lines \
    --wrap="auto" \
    ${HIGHLIGHT} \
    ${RANGE} \
    "$FILE"
else
  # Fallback when bat is not installed
  if [[ -n "$RANGE" ]]; then
    # Extract line numbers if requested
    IFS='=' read -r _ rng <<<"$RANGE"
    sed -n "${rng}p" "$FILE"
  else
    cat "$FILE"
  fi
fi

