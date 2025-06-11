#!/usr/bin/env bash
###############################################################################
#  fzf-script-picker  v1.3 – 2025-06-12
#  Fuzzy-find executable scripts and then ▸ insert ▸ print ▸ exec.
#
#  Defaults (no flags):
#     • scan    /usr/local/bin
#     • recurse 3 levels deep
#     • insert  the script basename at your prompt
#
#  Options:
#     -t, --target      scan these directories (comma- or space-separated)
#     -r, --recursive   [true|false] recurse?  (defaults true; "-r false" disables)
#     -x, --extensions  comma/space list of extensions to narrow the search
#     --action          insert|print|exec  (default: insert)
#     --exec            shortcut for --action exec
#     --extra-args      args for exec mode
#     -h, --help        this screen
###############################################################################
set -Eeuo pipefail

# ─── 1) GLOBAL DEFAULTS ─────────────────────────────────────────────────────
DEFAULT_TARGET="/usr/local/bin"
TARGETS=()
RECURSIVE=true
MAX_DEPTH=3
EXTENSIONS=""
ACTION="insert"      # now default is insert!
EXTRA_ARGS=""
THEME="Monokai Extended Bright"
WRAP="wrap"

# ─── 2) BAT OR CAT FOR HELP & PREVIEW ────────────────────────────────────────
if command -v bat &>/dev/null; then
  BAT_PRINT=(bat --style="grid,header,snip" \
                 --strip-ansi=always --squeeze-blank \
                 --pager="less -R" --paging=never \
                 --tabs=2 --wrap=auto \
                 --italic-text=always --theme="$THEME")
  BAT_PREVIEW=(bat --style="grid,header,snip" \
                   --strip-ansi=always --paging=never \
                   --terminal-width=-1 --theme="$THEME")
else
  BAT_PRINT=(cat)
  BAT_PREVIEW=(cat)
fi

# ─── 3) USAGE SCREEN ─────────────────────────────────────────────────────────
usage() {
  "${BAT_PRINT[@]}" <<EOF
NAME
    fzf-script-picker – fuzzy-select an executable script and insert/print/exec it.

SYNOPSIS
    fzf-script-picker [OPTIONS]

OPTIONS
    -t, --target <DIR1,DIR2…>
        One or more directories to scan.  Defaults to ${DEFAULT_TARGET}.

    -r, --recursive [true|false]
        Recurse into sub-folders (default: true).  Omit the value to enable.

    -x, --extensions <EXTS>
        Comma- or space-separated list (e.g. sh,py).  Leave empty to skip.

    --action <insert|print|exec>
        insert → splice basename into prompt  (default)
        print  → echo basename on stdout
        exec   → immediately run the full path

    --exec
        Shortcut for --action exec.

    --extra-args "<ARGS>"
        Extra arguments when using --action exec.

    -h, --help
        Show this help screen.

ENVIRONMENT
    BAT_THEME  Overrides the theme for bat.
EOF
}

# ─── 4) PARSE ARGS ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    -t|--target)
      IFS=', ' read -r -a more <<< "${2:?--target needs a value}"
      TARGETS+=("${more[@]}"); shift 2;;
    -r|--recursive)
      if [[ $# -ge 2 && $2 != -* ]]; then
        RECURSIVE=$2; shift 2
      else
        RECURSIVE=true; shift
      fi;;
    -x|--extensions)
      EXTENSIONS="${2//,/ }"; shift 2;;
    --action)
      ACTION=${2:?--action needs a value}; shift 2;;
    --exec)
      ACTION=exec; shift;;
    --extra-args)
      EXTRA_ARGS=$2; shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

# default to /usr/local/bin if no -t given
(( ${#TARGETS[@]} == 0 )) && TARGETS=("$DEFAULT_TARGET")

# sanity-check
[[ $ACTION =~ ^(insert|print|exec)$ ]] || { echo "Invalid --action"; exit 1; }
command -v fzf >/dev/null 2>&1 || { echo "fzf is required"; exit 1; }

# ─── 5) GATHER EXECUTABLES ───────────────────────────────────────────────────
have() { command -v "$1" &>/dev/null; }

# build extension filters for fd
EXT_FILTER=()
if [[ -n $EXTENSIONS ]]; then
  for e in $EXTENSIONS; do
    EXT_FILTER+=( -e "$e" )
  done
fi

# recursion flags
if [[ $RECURSIVE == true ]]; then
  DEPFLAGS=()
else
  DEPFLAGS=( --max-depth "$MAX_DEPTH" )
fi

collect_files() {
  local dir=$1
  if have fd; then
    fd --type f "${DEPFLAGS[@]}" "${EXT_FILTER[@]}" --search-path "$dir"
  else
    local md=""
    [[ $RECURSIVE != true ]] && md="-maxdepth $MAX_DEPTH"
    find "$dir" $md -type f 2>/dev/null
  fi
}

# apply executability filter + sort uniq
mapfile -t CANDIDATES < <(
  for d in "${TARGETS[@]}"; do
    [[ -d $d ]] || { echo "⚠  '$d' not a directory; skipping." >&2; continue; }
    collect_files "$d"
  done \
  | while IFS= read -r f; do
      [[ -x $f ]] && printf '%s\n' "$f"
    done \
  | sort -u
)
(( ${#CANDIDATES[@]} )) || { echo "No executable scripts found."; exit 1; }

# ─── 6) FUZZY-SELECT ─────────────────────────────────────────────────────────
SELECTED=$(printf '%s\n' "${CANDIDATES[@]}" \
  | fzf \
      --prompt="Scripts> " \
      --header="Choose script to ${ACTION}" \
      --preview="${BAT_PREVIEW[*]} -- {}" \
      --preview-window=right:60%:$WRAP)

[[ -z $SELECTED ]] && exit 1   # aborted

# ─── 7) DO THE THING ────────────────────────────────────────────────────────
BASE=$(basename "$SELECTED")

case $ACTION in
  insert)
    if [[ -n ${ZSH_VERSION:-} ]]; then
      print -nz -- "$BASE "
    elif [[ -n ${BASH_VERSION:-} ]]; then
      READLINE_LINE=${READLINE_LINE:0:$READLINE_POINT}"$BASE "${READLINE_LINE:$READLINE_POINT}
      READLINE_POINT=$(( READLINE_POINT + ${#BASE} + 1 ))
    else
      printf '%s\n' "$BASE"
    fi
    ;;
  print)
    printf '%s\n' "$BASE"
    ;;
  exec)
    # run the full path (so we don’t accidentally pick another $PATH entry)
    "$SELECTED" $EXTRA_ARGS
    ;;
esac

