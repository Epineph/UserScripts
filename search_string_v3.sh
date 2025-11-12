#!/usr/bin/env bash
#
# search-string — find files with a string and show line numbers
#
# Usage:
#   search-string [options] <pattern>
#
# Options:
#   -i, --ignore-case         Do case-insensitive matching
#   -e, --exts <list>         Comma-separated extensions (e.g. "c,py,md"); defaults to all files
#   -s, --search-path <path>  Directory to start search (default: "$(pwd)")
#   -r, --recursive           Recurse fully (no depth limit)
#   -d, --depth <n>           Limit recursion depth to n (default: 3 if neither -r nor -d given)
#   -I, --interactive         Pipe results through fzf for interactive filtering + preview
#   -h, --help                Show this help and exit
#
# Examples:
#   # Search for "TODO" in current directory up to depth 3 (default):
#   search-string "TODO"
#
#   # Search for "malloc" case-insensitively in .c and .h files under /home/src up to depth 5:
#   search-string -i -e c,h -s /home/src -d 5 "malloc"
#
#   # Search recursively in /mnt for "token" across all extensions:
#   search-string -r -s /mnt "token"
#
# Dependencies:
#   • fd  (https://github.com/sharkdp/fd)
#   • grep
#   • fzf  (only for --interactive)
#
# Logic:
#   1. Parse options and set SEARCH_PATH, RECURSIVE flag, DEPTH.
#   2. Build fd arguments: extensions, recursion flags, path.
#   3. Use fd to list candidate files.
#   4. For each file, run grep -Hn (header + line numbers).
#   5. If interactive, feed through fzf with preview.
#
set -euo pipefail

# — Defaults —
IGNORE_CASE=
EXTS=
INTERACTIVE=
SEARCH_PATH="$(pwd)"
RECURSIVE=0
DEPTH=

# — Help —
show_help() {
  sed -n '1,50p' "$0" | sed 's/^# \?//'
  exit 0
}

# — Parse args —
while (( $# )); do
  case $1 in
    -i|--ignore-case)    IGNORE_CASE="-i"; shift;;
    -e|--exts)           EXTS="$2"; shift 2;;
    -s|--search-path)    SEARCH_PATH="$2"; shift 2;;
    -r|--recursive)      RECURSIVE=1; shift;;
    -d|--depth)          DEPTH="$2"; shift 2;;
    -I|--interactive)    INTERACTIVE=1; shift;;
    -h|--help)           show_help;;
    --) shift; break;;
    -* ) echo "Unknown option: $1" >&2; exit 1;;
    * ) PATTERN="$1"; shift; break;;
  esac
done

# Validate pattern
if [[ -z "${PATTERN:-}" ]]; then
  echo "Error: <pattern> is required" >&2
  show_help
fi

# Determine recursion flags for fd
FD_RECURSE_ARGS=()
if (( RECURSIVE )); then
  # full recursion: no --max-depth
  :
elif [[ -n "$DEPTH" ]]; then
  FD_RECURSE_ARGS+=( --max-depth "$DEPTH" )
else
  # default depth = 3
  FD_RECURSE_ARGS+=( --max-depth 3 )
fi

# Build fd args: extensions, recursion, path
FD_ARGS=()
if [[ -n "$EXTS" ]]; then
  IFS=, read -ra _extlist <<< "$EXTS"
  for _ext in "${_extlist[@]}"; do
    FD_ARGS+=( -e "$_ext" )
  done
fi
FD_ARGS+=( "${FD_RECURSE_ARGS[@]}" . "$SEARCH_PATH" )

# Grep options: -H (filename), -n (line no), plus optional -i
GREP_OPTS=( -Hn )
[[ -n "$IGNORE_CASE" ]] && GREP_OPTS+=( -i )
GREP_OPTS+=( -- "$PATTERN" )

# Execute fd + grep without eval to avoid parsing issues
if [[ -n "${INTERACTIVE:-}" ]]; then
  fd "${FD_ARGS[@]}" -x grep "${GREP_OPTS[@]}" {} + |
    fzf --ansi --delimiter : \
        --nth=1,2,3 \
        --preview "grep --color=always -C2 ${IGNORE_CASE} -- '${PATTERN}' {1}" \
        --preview-window=right:60%
else
  fd "${FD_ARGS[@]}" -x grep "${GREP_OPTS[@]}" {} +
fi

