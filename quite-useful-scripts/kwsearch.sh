#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# kwsearch — literal keyword finder across files and directories (opt. recurse)
# ──────────────────────────────────────────────────────────────────────────────
# Features (concise):
#   • -k/--keywords  : comma-separated keywords; literal match (spaces allowed)
#   • -t/--targets   : comma-separated paths (files and/or directories)
#   • -r/--recursive : recurse into directories
#   • -i/--ignore-case : case-insensitive search
#   • -H/--hidden    : include hidden files (ripgrep backend only)
#   • -n/--narrate   : enable brief progress “theatrics”
#   • --clear        : clear the screen during narration
#   • Robust: uses ripgrep when available; portable grep+find fallback
#   • Output: lists per-keyword matches + per-file summary with realpaths
#   • Exit codes: 0=matches found, 2=no matches, 1=error
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Global defaults
# ──────────────────────────────────────────────────────────────────────────────
declare -a KEYWORDS=()
declare -a TARGETS=()

RECURSIVE=0
NARRATE=0
CLEAR=0
CASE_SENSITIVE=1
INCLUDE_HIDDEN=0

# Associative sets
declare -A MATCHED_FILES_BY_KW=() # key: keyword -> newline-separated realpaths
declare -A MATCHED_KWS_BY_FILE=() # key: realpath -> comma-separated keywords

# ──────────────────────────────────────────────────────────────────────────────
# Pager selection for help (prefers HELP_PAGER, then helpout/batwrap/bat, else cat)
# ──────────────────────────────────────────────────────────────────────────────
function _help_pager() {
  if [[ -n "${HELP_PAGER:-}" ]]; then
    printf '%s\n' "$HELP_PAGER"
    return
  fi
  if command -v helpout >/dev/null 2>&1; then
    printf '%s\n' "helpout"
  elif command -v batwrap >/dev/null 2>&1; then
    printf '%s\n' "batwrap"
  elif command -v bat >/dev/null 2>&1; then
    printf '%s\n' "bat --style='grid,header,snip' --italic-text='always' \
      --theme='gruvbox-dark' --squeeze-blank --squeeze-limit='2' \
      --force-colorization --terminal-width='auto' --tabs='2' \
      --paging='never' --chop-long-lines"
  elif command -v less >/dev/null 2>&1; then
    printf '%s\n' "less -R"
  else
    printf '%s\n' "cat"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Usage / Help
# ──────────────────────────────────────────────────────────────────────────────
function show_help() {
  local pager
  pager="$(_help_pager)"
  # shellcheck disable=SC2016
  eval "$pager" <<'HLP'
kwsearch — literal keyword finder across files and directories (opt. recurse)
───────────────────────────────────────────────────────────────────────────────
USAGE
  kwsearch -k "<kw1,kw2,...>" -t "<path1,path2,...>" [options]

REQUIRED
  -k, --keywords   Comma-separated list of literal keywords to search for.
                   Examples: -k "nerd-fonts"
                             -k "nerd-fonts,sudo systemctl reboot"
                   Keywords are treated as fixed strings (NOT regex).
  -t, --targets    Comma-separated paths: files and/or directories.
                   Example: -t "$HOME/Documents,$HOME/repos"

OPTIONS
  -r, --recursive         Recurse into directory targets.
  -i, --ignore-case       Case-insensitive search (default: case-sensitive).
  -H, --hidden            Include hidden files (ripgrep backend only).
  -n, --narrate           Brief progress narration with dots.
      --clear             Clear screen before narration steps.
  -h, --help              Show this help and exit.

BEHAVIOR
  • Reports, for each keyword, the files (as realpaths) where it was found.
  • Also prints a per-file summary listing all matched keywords in that file.
  • Exit 0 if any matches are found; 2 if no matches; 1 on errors.

EXAMPLES
  # One keyword, one directory, non-recursive (depth=1)
  kwsearch -k "nerd-fonts" -t "$HOME/Documents"

  # Two keywords, two directories, recursive, with narration
  kwsearch -k "nerd-fonts,sudo systemctl reboot" \
           -t "$HOME/Documents,$HOME/repos" -r -n

  # Case-insensitive search in a file and a directory
  kwsearch -k "Foo,Bar baz" -t "$HOME/file.txt,$HOME/src" -i

NOTES
  • Uses ripgrep (rg) if available for speed; otherwise falls back to grep+find.
  • Keyword and target lists accept spaces; they are split strictly on commas.
  • For non-recursive directory scans with grep fallback, only depth=1 is used.

HLP
}

# ──────────────────────────────────────────────────────────────────────────────
# Utilities
# ──────────────────────────────────────────────────────────────────────────────
function die() {
  printf 'kwsearch: %s\n' "$*" >&2
  exit 1
}

function trim() {
  local s="$*"
  # shellcheck disable=SC2001
  s="$(sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//' <<<"$s")"
  printf '%s' "$s"
}

function parse_csv_into_array() {
  local input="$1"
  local -n out_arr="$2"
  local IFS=','
  read -r -a _tmp <<<"$input"
  local x
  for x in "${_tmp[@]}"; do
    x="$(trim "$x")"
    [[ -n "$x" ]] && out_arr+=("$x")
  done
}

function realpath_portable() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -e -- "$p" 2>/dev/null || printf '%s' "$p"
  else
    readlink -f -- "$p" 2>/dev/null || printf '%s' "$p"
  fi
}

function join_and_quote() {
  # Prints: 'a', 'b', 'c'
  local sep="${1:-, }"
  shift || true
  local out=()
  local s
  for s in "$@"; do out+=("'$s'"); done
  local IFS="$sep"
  printf '%s' "${out[*]}"
}

function list_targets_plain() {
  local IFS=', '
  printf '%s' "$*"
}

function append_unique_line() {
  # args: varname string_to_append
  local -n ref="$1"
  local item="$2"
  if [[ -z "${ref:-}" ]]; then
    ref="$item"
    return
  fi
  # membership test on newline-separated list
  if ! grep -Fxq -- "$item" <<<"$ref"; then
    ref+=$'\n'"$item"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Narration (optional theatrics)
# ──────────────────────────────────────────────────────────────────────────────
function narrate() {
  [[ $NARRATE -eq 1 ]] || return 0
  local msg="$1"
  if [[ $CLEAR -eq 1 ]]; then clear; fi
  printf '%s\n' "$msg"
  sleep 0.6
}

function narrate_dots() {
  [[ $NARRATE -eq 1 ]] || return 0
  local msg="$1" i
  printf '%s ' "$msg"
  for i in 1 2 3; do
    printf '.'
    sleep 0.35
  done
  printf '\n'
}

# ──────────────────────────────────────────────────────────────────────────────
# Backend selection
# ──────────────────────────────────────────────────────────────────────────────
function have_rg() { command -v rg >/dev/null 2>&1; }

# Emit NUL-delimited file list containing $1 within $2
function search_emit_files_nul() {
  local kw="$1" tgt="$2"
  if have_rg; then
    # ripgrep: fixed strings, filenames only, NUL delim, no color
    local args=(-F -l -0 --color=never)
    [[ $RECURSIVE -eq 0 ]] && args+=(--max-depth 1)
    [[ $CASE_SENSITIVE -eq 0 ]] && args+=(-i)
    [[ $INCLUDE_HIDDEN -eq 1 ]] && args+=(--hidden)
    rg "${args[@]}" -e "$kw" -- "$tgt" 2>/dev/null || true
  else
    # grep fallback: care for dirs vs files; ensure null delim; ignore binary
    local gargs=(-I -F -l -Z)
    [[ $CASE_SENSITIVE -eq 0 ]] && gargs+=(-i)
    if [[ -d "$tgt" ]]; then
      if [[ $RECURSIVE -eq 1 ]]; then
        grep -R "${gargs[@]}" -- "$kw" "$tgt" 2>/dev/null || true
      else
        find "$tgt" -maxdepth 1 -type f -print0 |
          xargs -0r grep "${gargs[@]}" -- "$kw" 2>/dev/null || true
      fi
    else
      # Single file (exists check later)
      grep "${gargs[@]}" -- "$kw" "$tgt" 2>/dev/null || true
    fi
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────────────────────────────────────
function parse_args() {
  [[ $# -gt 0 ]] || {
    show_help
    exit 1
  }
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -k | --keyword | --keywords)
      [[ $# -ge 2 ]] || die "Missing value after $1"
      parse_csv_into_array "$2" KEYWORDS
      shift 2
      ;;
    -t | --target | --targets)
      [[ $# -ge 2 ]] || die "Missing value after $1"
      parse_csv_into_array "$2" TARGETS
      shift 2
      ;;
    -r | --recursive | --recursion)
      RECURSIVE=1
      shift
      ;;
    -i | --ignore-case)
      CASE_SENSITIVE=0
      shift
      ;;
    -H | --hidden)
      INCLUDE_HIDDEN=1
      shift
      ;;
    -n | --narrate)
      NARRATE=1
      shift
      ;;
    --clear)
      CLEAR=1
      shift
      ;;
    -h | --help)
      show_help
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "Unknown option: $1 (see --help)"
      ;;
    *)
      die "Unexpected argument: $1 (see --help)"
      ;;
    esac
  done

  [[ ${#KEYWORDS[@]} -ge 1 ]] || die "At least one keyword is required (-k)."
  [[ ${#TARGETS[@]} -ge 1 ]] || die "At least one target is required (-t)."
}

# ──────────────────────────────────────────────────────────────────────────────
# Validation + prelude messages
# ──────────────────────────────────────────────────────────────────────────────
function validate_targets() {
  local t ok_any=0
  for t in "${TARGETS[@]}"; do
    if [[ -e "$t" ]]; then
      ok_any=1
      continue
    else
      printf 'Warning: target not found: %s\n' "$t" >&2
    fi
  done
  [[ $ok_any -eq 1 ]] || die "None of the targets exist."
}

function intro_messages() {
  local kcount=${#KEYWORDS[@]} tcount=${#TARGETS[@]}
  local kw_phrase="keyword"
  [[ $kcount -gt 1 ]] && kw_phrase="keywords"
  local tgt_phrase="target"
  [[ $tcount -gt 1 ]] && tgt_phrase="targets"

  narrate "Preparing search..."
  narrate_dots "User requested $kw_phrase: $(join_and_quote ', ' "${KEYWORDS[@]}")"
  if [[ $tcount -gt 1 ]]; then
    narrate_dots "User provided $tgt_phrase: $(list_targets_plain "${TARGETS[@]}")"
  else
    narrate_dots "Selected $tgt_phrase: $(list_targets_plain "${TARGETS[@]}")"
  fi

  if [[ $RECURSIVE -eq 1 ]]; then
    if [[ $tcount -gt 1 && $kcount -gt 1 ]]; then
      narrate "Recursion enabled — will scan all targets recursively for all \
$kw_phrase."
    elif [[ $tcount -gt 1 ]]; then
      narrate "Recursion enabled — will scan all targets recursively for the \
$kw_phrase."
    else
      narrate "Recursion enabled — will scan the selected target recursively."
    fi
  else
    narrate "Non-recursive — depth limited to the top of each directory target."
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Core search
# ──────────────────────────────────────────────────────────────────────────────
function perform_search() {
  local kw tgt f rp
  for kw in "${KEYWORDS[@]}"; do
    for tgt in "${TARGETS[@]}"; do
      [[ -e "$tgt" ]] || continue
      while IFS= read -r -d '' f; do
        rp="$(realpath_portable "$f")"
        append_unique_line MATCHED_FILES_BY_KW["$kw"] "$rp"

        # add keyword to per-file list (comma-separated, unique)
        if [[ -z "${MATCHED_KWS_BY_FILE[$rp]:-}" ]]; then
          MATCHED_KWS_BY_FILE["$rp"]="$kw"
        else
          if ! grep -Fq -- "$kw" <<<",${MATCHED_KWS_BY_FILE[$rp]},"; then
            MATCHED_KWS_BY_FILE["$rp"]+=",${kw}"
          fi
        fi
      done < <(search_emit_files_nul "$kw" "$tgt")
    done
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# Reporting
# ──────────────────────────────────────────────────────────────────────────────
function print_report() {
  local any=0 kw block count
  printf '─────────────────────────────────────────────────────────────────────────\n'
  printf 'Keyword-wise results\n'
  printf '─────────────────────────────────────────────────────────────────────────\n'
  for kw in "${KEYWORDS[@]}"; do
    block="${MATCHED_FILES_BY_KW[$kw]:-}"
    if [[ -z "$block" ]]; then
      printf "• '%s': no matches in the selected %s%s.\n" \
        "$kw" \
        "$([[ ${#TARGETS[@]} -gt 1 ]] && printf 'targets' || printf 'target')" \
        "$([[ $RECURSIVE -eq 1 ]] && printf ' (recursive)' || printf '')"
      continue
    fi
    any=1
    count=$(grep -c '' <<<"$block" || true)
    printf "• '%s': %d file%s\n" "$kw" "$count" "$([[ $count -ne 1 ]] && echo 's' || echo '')"
    # print file list
    while IFS= read -r line; do
      printf "    - %s\n" "$line"
    done <<<"$block"
  done

  printf '─────────────────────────────────────────────────────────────────────────\n'
  printf 'Per-file summary\n'
  printf '─────────────────────────────────────────────────────────────────────────\n'
  if [[ ${#MATCHED_KWS_BY_FILE[@]} -eq 0 ]]; then
    printf "No files containing %s %s found%s.\n" \
      "$([[ ${#KEYWORDS[@]} -gt 1 ]] && printf 'the keywords' || printf 'the keyword')" \
      "$(join_and_quote ', ' "${KEYWORDS[@]}")" \
      "$([[ $RECURSIVE -eq 1 ]] && printf ' (recursive)' || printf '')"
  else
    local file
    for file in "${!MATCHED_KWS_BY_FILE[@]}"; do
      printf "• %s\n" "$file"
      printf "    contains: %s\n" "$(join_and_quote ', ' "${MATCHED_KWS_BY_FILE[$file]//,/ }")"
    done
  fi

  return "$any"
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
function main() {
  parse_args "$@"
  validate_targets
  intro_messages
  perform_search
  if print_report; then
    exit 0
  else
    exit 2
  fi
}

main "$@"
