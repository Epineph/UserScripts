#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# fdc: "fd for contents" wrapper around ripgrep (rg), optionally prefiltered
#      by fd. Prints file:line:column matches (and context if requested).
#
# Dependencies:
#   - required: ripgrep (rg)
#   - optional: fd (only used when --name is provided)
#
# Usage:
#   fdc [options] <PATTERN> [PATH...]
# -----------------------------------------------------------------------------

set -euo pipefail

function die() {
  printf 'fdc: %s\n' "$1" >&2
  exit 1
}

function have() {
  command -v "$1" >/dev/null 2>&1
}

function help_text() {
  cat <<'EOF'
fdc - content search (ripgrep) with optional fd filename prefilter

USAGE
  fdc [options] <PATTERN> [PATH...]

OPTIONS
  -h, --help
      Show this help.

  -m, --mode <fast|full>
      Search mode (case-insensitive):
        fast  - respects ignore files, hidden excluded (default)
        full  - includes hidden, ignores disabled, follows symlinks

  -i, --ignore-case
      Force case-insensitive matching.

  -s, --smart-case
      Smart case (default): case-insensitive unless PATTERN has capitals.

  -F, --fixed
      Treat PATTERN as a literal string (not a regex).

  -w, --word
      Match whole words only.

  -C, --context <N>
      Show N lines of context before and after each match.

  -A, --after <N>
      Show N lines of context after each match.

  -B, --before <N>
      Show N lines of context before each match.

  -g, --glob <GLOB>
      Restrict search with a glob (can be repeated), e.g. -g '*.R' -g '!*.csv'

  -t, --type <TYPE>
      Restrict search by ripgrep type (can be repeated), e.g. -t rust -t py

  --hidden
      Include hidden files and directories.

  --no-ignore
      Do not respect .gitignore/.ignore/etc.

  --follow
      Follow symlinks.

  --name <FD_PATTERN>
      Prefilter filenames using fd before searching contents with rg.
      Requires fd. FD_PATTERN is fd's pattern (regex by default).

  --pager
      Pipe output through ${PAGER:-less -R} (colors preserved).

EXAMPLES
  fdc -n 'TODO' .
  fdc -C 2 'hippocampus' ~/notes
  fdc -g '*.R' 'lmer\\(' .
  fdc --name '\\.sh$' -n 'set -euo pipefail' /usr/local/bin
  fdc --mode full -i 'password' /etc

NOTES
  - PATTERN is interpreted as a regex unless you pass --fixed.
  - Output is file:line:column with match highlighting (rg default).
EOF
}

function show_help() {
  local pager="${HELP_PAGER:-${PAGER:-less -R}}"
  if [[ -t 1 ]]; then
    help_text | eval "$pager"
  else
    help_text
  fi
}

# ------------------------------- Defaults ------------------------------------

mode="fast"
use_pager=0
fd_name_pattern=""
declare -a paths
declare -a rg_opts
declare -a fd_opts

# rg defaults
rg_opts+=(--line-number --column)
rg_opts+=(--smart-case)

# ------------------------------ Arg parsing ----------------------------------

pattern=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    -m|--mode)
      [[ $# -ge 2 ]] || die "missing value for --mode"
      mode="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
      shift 2
      ;;
    -i|--ignore-case)
      rg_opts+=(--ignore-case)
      shift
      ;;
    -s|--smart-case)
      # Keep explicit for clarity; already default.
      rg_opts+=(--smart-case)
      shift
      ;;
    -F|--fixed)
      rg_opts+=(--fixed-strings)
      shift
      ;;
    -w|--word)
      rg_opts+=(--word-regexp)
      shift
      ;;
    -C|--context)
      [[ $# -ge 2 ]] || die "missing value for --context"
      rg_opts+=(-C "$2")
      shift 2
      ;;
    -A|--after)
      [[ $# -ge 2 ]] || die "missing value for --after"
      rg_opts+=(-A "$2")
      shift 2
      ;;
    -B|--before)
      [[ $# -ge 2 ]] || die "missing value for --before"
      rg_opts+=(-B "$2")
      shift 2
      ;;
    -g|--glob)
      [[ $# -ge 2 ]] || die "missing value for --glob"
      rg_opts+=(--glob "$2")
      shift 2
      ;;
    -t|--type)
      [[ $# -ge 2 ]] || die "missing value for --type"
      rg_opts+=(--type "$2")
      shift 2
      ;;
    --hidden)
      rg_opts+=(--hidden)
      fd_opts+=(--hidden)
      shift
      ;;
    --no-ignore)
      rg_opts+=(--no-ignore)
      shift
      ;;
    --follow)
      rg_opts+=(--follow)
      shift
      ;;
    --name)
      [[ $# -ge 2 ]] || die "missing value for --name"
      fd_name_pattern="$2"
      shift 2
      ;;
    --pager)
      use_pager=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1 (try --help)"
      ;;
    *)
      if [[ -z "$pattern" ]]; then
        pattern="$1"
      else
        paths+=("$1")
      fi
      shift
      ;;
  esac
done

# Remaining args after -- are paths (if pattern already set)
while [[ $# -gt 0 ]]; do
  if [[ -z "$pattern" ]]; then
    pattern="$1"
  else
    paths+=("$1")
  fi
  shift
done

[[ -n "$pattern" ]] || { show_help; exit 2; }
[[ ${#paths[@]} -gt 0 ]] || paths=(".")

have rg || die "missing dependency: rg (ripgrep)"

case "$mode" in
  fast) : ;;
  full)
    rg_opts+=(--hidden --no-ignore --follow)
    fd_opts+=(--hidden)
    ;;
  *)
    die "invalid --mode '$mode' (use fast|full)"
    ;;
esac

# Force colors when piping to a pager (so highlighting survives).
if [[ $use_pager -eq 1 ]]; then
  rg_opts+=(--color always)
fi

# ------------------------------- Execution -----------------------------------

if [[ -n "$fd_name_pattern" ]]; then
  have fd || die "--name requires fd (install 'fd' or remove --name)"

  # fd finds files; xargs feeds them to rg as explicit file arguments.
  # This avoids rg's own traversal when you want tight filename control.
  #
  # Note: fd pattern is regex by default. Use a safe, explicit regex
  # (e.g., '\.sh$') or pass something broader and rely on --glob.
  cmd_fd=(fd --type f --color never "${fd_opts[@]}" -- "$fd_name_pattern" "${paths[@]}")
  cmd_rg=(rg "${rg_opts[@]}" -- "$pattern")

  if [[ $use_pager -eq 1 ]]; then
    "${cmd_fd[@]}" -0 | xargs -0 -r "${cmd_rg[@]}" | eval "${PAGER:-less -R}"
  else
    "${cmd_fd[@]}" -0 | xargs -0 -r "${cmd_rg[@]}"
  fi
else
  cmd_rg=(rg "${rg_opts[@]}" -- "$pattern" "${paths[@]}")

  if [[ $use_pager -eq 1 ]]; then
    "${cmd_rg[@]}" | eval "${PAGER:-less -R}"
  else
    "${cmd_rg[@]}"
  fi
fi

