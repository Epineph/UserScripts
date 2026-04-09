#!/usr/bin/env bash

set -euo pipefail

# -----------------------------------------------------------------------------
# bat-wrapper-modern
# -----------------------------------------------------------------------------
# Default behavior:
#   - discover matching files
#   - print basename + realpath
#   - print total count
#   - show only the first N matches (default: 100)
#
# Optional:
#   - render file contents with bat via --content
#   - filter by extension(s)
#   - filter by keyword(s)
#   - recurse with configurable depth
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
DEFAULT_COUNT=100
COUNT="$DEFAULT_COUNT"
MAX_DEPTH=3
RECURSIVE=false
SHOW_CONTENT=false
KEYWORD=""
EXTENSIONS=()
TARGETS=()

BAT_BIN="${BAT_BIN:-bat}"
FD_BIN="${FD_BIN:-fd}"
FIND_BIN="${FIND_BIN:-find}"
REALPATH_BIN="${REALPATH_BIN:-realpath}"

# Conservative bat defaults for explicit content rendering only
BAT_PAGING="never"
BAT_STYLE="grid,header"
BAT_DECORATIONS="always"
BAT_COLOR="always"
BAT_WRAP="auto"
BAT_THEME="Monokai Extended Bright"
BAT_LANGUAGE=""

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
function have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function usage() {
  cat <<'EOF'
Usage:
  bat-wrapper-modern -t <path...> [options]

Purpose:
  Discover files safely by default, showing only:
    - file name
    - realpath
    - total count

Default behavior:
  - show at most 100 matches
  - if more than 100 are found, say so
  - do NOT print file contents unless --content is used

Options:
  -t, --target <path...>         One or more target files/directories
  -r, --recursive [depth]        Recurse; optional max depth (default: 3)
  -x, --extensions <exts...>     Filter by extension(s), comma or space
  -k, --keyword <text>           Filter matched paths by keyword (basic)
  -n, --count <N>                Number of entries to show (default: 100)
      --content                  Render matched file contents with bat
      --theme <theme>            bat theme for --content mode
  -l, --language <lang>          Force bat language in --content mode
  -h, --help                     Show help

Notes:
  - Count controls how many matching paths are shown, not how many exist.
  - Total match count is always computed first.
  - Keyword filtering is optional and intentionally simple.

Examples:
  bat-wrapper-modern -t "$PWD"

  bat-wrapper-modern -t "$HOME/repos" -r 2 -x "sh,py,md"

  bat-wrapper-modern -t "$HOME" -r 4 -n 25

  bat-wrapper-modern -t . -r 3 -x "R,Rmd" -k stress

  bat-wrapper-modern -t ./script.sh --content

  bat-wrapper-modern -t ~/repos -r 2 -x "lua" -n 10 --content
EOF
}

function split_csv_or_space() {
  local input="$1"
  input="${input//,/ }"
  printf '%s\n' $input
}

function normalize_realpath() {
  local p="$1"

  if have_cmd "$REALPATH_BIN"; then
    "$REALPATH_BIN" "$p" 2>/dev/null || printf '%s\n' "$p"
  elif have_cmd readlink; then
    readlink -f "$p" 2>/dev/null || printf '%s\n' "$p"
  else
    printf '%s\n' "$p"
  fi
}

function is_text_like() {
  local file="$1"

  if file --mime "$file" 2>/dev/null | grep -qiE \
    'charset=(us-ascii|utf-8|utf-16|iso-8859|unknown-8bit)|text/'; then
    return 0
  fi

  return 1
}

function add_targets_from_arg() {
  local value="$1"
  local entry

  while IFS= read -r entry; do
    [[ -n "$entry" ]] && TARGETS+=("$entry")
  done < <(split_csv_or_space "$value")
}

function add_extensions_from_arg() {
  local value="$1"
  local ext

  while IFS= read -r ext; do
    [[ -n "$ext" ]] && EXTENSIONS+=("${ext#.}")
  done < <(split_csv_or_space "$value")
}

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)
      [[ $# -ge 2 ]] || die "$1 requires an argument"
      add_targets_from_arg "$2"
      shift 2
      ;;
    -r|--recursive)
      RECURSIVE=true
      if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then
        MAX_DEPTH="$2"
        shift 2
      else
        shift
      fi
      ;;
    -x|--extensions)
      [[ $# -ge 2 ]] || die "$1 requires an argument"
      add_extensions_from_arg "$2"
      shift 2
      ;;
    -k|--keyword)
      [[ $# -ge 2 ]] || die "$1 requires an argument"
      KEYWORD="$2"
      shift 2
      ;;
    -n|--count)
      [[ $# -ge 2 ]] || die "$1 requires an argument"
      [[ "$2" =~ ^[0-9]+$ ]] || die "--count expects a non-negative integer"
      COUNT="$2"
      shift 2
      ;;
    --content)
      SHOW_CONTENT=true
      shift
      ;;
    --theme)
      [[ $# -ge 2 ]] || die "$1 requires an argument"
      BAT_THEME="$2"
      shift 2
      ;;
    -l|--language)
      [[ $# -ge 2 ]] || die "$1 requires an argument"
      BAT_LANGUAGE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        TARGETS+=("$1")
        shift
      done
      ;;
    *)
      TARGETS+=("$1")
      shift
      ;;
  esac
done

[[ "${#TARGETS[@]}" -gt 0 ]] || die "no targets specified"

# -----------------------------------------------------------------------------
# Build file list
# -----------------------------------------------------------------------------
MATCHES=()

function collect_with_fd() {
  local tgt="$1"
  local cmd=()

  if [[ -f "$tgt" ]]; then
    printf '%s\0' "$tgt"
    return 0
  fi

  [[ -d "$tgt" ]] || return 0

  cmd=("$FD_BIN" "--type" "f" "--hidden" "--follow" "--print0"
       "--search-path" "$tgt")

  if [[ "$RECURSIVE" == false ]]; then
    cmd+=("--max-depth" "1")
  else
    cmd+=("--max-depth" "$MAX_DEPTH")
  fi

  if [[ "${#EXTENSIONS[@]}" -gt 0 ]]; then
    local ext
    for ext in "${EXTENSIONS[@]}"; do
      cmd+=("-e" "$ext")
    done
  fi

  "${cmd[@]}" 2>/dev/null
}

function collect_with_find() {
  local tgt="$1"

  if [[ -f "$tgt" ]]; then
    printf '%s\0' "$tgt"
    return 0
  fi

  [[ -d "$tgt" ]] || return 0

  local depth=()
  if [[ "$RECURSIVE" == false ]]; then
    depth=(-maxdepth 1)
  else
    depth=(-maxdepth "$MAX_DEPTH")
  fi

  if [[ "${#EXTENSIONS[@]}" -gt 0 ]]; then
    local expr=()
    local i ext
    for i in "${!EXTENSIONS[@]}"; do
      ext="${EXTENSIONS[$i]}"
      if [[ "$i" -gt 0 ]]; then
        expr+=(-o)
      fi
      expr+=(-iname "*.${ext}")
    done
    "$FIND_BIN" "$tgt" "${depth[@]}" -type f \( "${expr[@]}" \) -print0 \
      2>/dev/null
  else
    "$FIND_BIN" "$tgt" "${depth[@]}" -type f -print0 2>/dev/null
  fi
}

function collect_matches() {
  local tgt file

  for tgt in "${TARGETS[@]}"; do
    if have_cmd "$FD_BIN"; then
      while IFS= read -r -d '' file; do
        MATCHES+=("$file")
      done < <(collect_with_fd "$tgt")
    else
      while IFS= read -r -d '' file; do
        MATCHES+=("$file")
      done < <(collect_with_find "$tgt")
    fi
  done
}

collect_matches

# -----------------------------------------------------------------------------
# Deduplicate
# -----------------------------------------------------------------------------
if [[ "${#MATCHES[@]}" -gt 0 ]]; then
  mapfile -t MATCHES < <(
    printf '%s\n' "${MATCHES[@]}" | awk '!seen[$0]++'
  )
fi

# -----------------------------------------------------------------------------
# Optional keyword filter
# -----------------------------------------------------------------------------
if [[ -n "$KEYWORD" && "${#MATCHES[@]}" -gt 0 ]]; then
  mapfile -t MATCHES < <(
    printf '%s\n' "${MATCHES[@]}" | grep -i -- "$KEYWORD" || true
  )
fi

TOTAL_FOUND="${#MATCHES[@]}"

# -----------------------------------------------------------------------------
# Report discovery results
# -----------------------------------------------------------------------------
printf 'Targets      : %s\n' "${TARGETS[*]}"
printf 'Recursive    : %s\n' "$RECURSIVE"
printf 'Max depth    : %s\n' "$MAX_DEPTH"
printf 'Keyword      : %s\n' "${KEYWORD:-<none>}"

if [[ "${#EXTENSIONS[@]}" -gt 0 ]]; then
  printf 'Extensions   : %s\n' "${EXTENSIONS[*]}"
else
  printf 'Extensions   : %s\n' "<all>"
fi

printf 'Found        : %d\n' "$TOTAL_FOUND"
printf 'Show limit    : %d\n' "$COUNT"

if [[ "$TOTAL_FOUND" -eq 0 ]]; then
  exit 0
fi

if [[ "$TOTAL_FOUND" -gt "$COUNT" ]]; then
  printf 'Notice       : more than %d matches found; showing first %d\n' \
    "$COUNT" "$COUNT"
fi

# -----------------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------------
SHOW_N="$COUNT"
if [[ "$TOTAL_FOUND" -lt "$SHOW_N" ]]; then
  SHOW_N="$TOTAL_FOUND"
fi

if [[ "$SHOW_CONTENT" == false ]]; then
  i=0
  while [[ "$i" -lt "$SHOW_N" ]]; do
    file="${MATCHES[$i]}"
    printf '[%d] %s\n' "$((i + 1))" "$(basename "$file")"
    printf '     %s\n' "$(normalize_realpath "$file")"
    ((i += 1))
  done
  exit 0
fi

# -----------------------------------------------------------------------------
# Explicit content rendering mode
# -----------------------------------------------------------------------------
if ! have_cmd "$BAT_BIN"; then
  die "'bat' is required for --content mode"
fi

BAT_CMD=(
  "$BAT_BIN"
  "--paging=$BAT_PAGING"
  "--style=$BAT_STYLE"
  "--decorations=$BAT_DECORATIONS"
  "--color=$BAT_COLOR"
  "--wrap=$BAT_WRAP"
  "--theme=$BAT_THEME"
)

if [[ -n "$BAT_LANGUAGE" ]]; then
  BAT_CMD+=("--language=$BAT_LANGUAGE")
fi

i=0
while [[ "$i" -lt "$SHOW_N" ]]; do
  file="${MATCHES[$i]}"

  if is_text_like "$file"; then
    "${BAT_CMD[@]}" "$file"
  else
    printf 'Skipping non-text-like file: %s\n' "$file" >&2
  fi

  ((i += 1))
done
