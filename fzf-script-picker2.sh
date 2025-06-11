#!/usr/bin/env bash
###############################################################################
#  fzf-script-picker
#  -----------------
#  Fuzzy-find executable scripts in one or more directories
#  and then  ▸ print  ▸ insert  ▸ or exec  the selection.
#
#  Default behaviour (no flags):
#      • scan  /usr/local/bin
#      • recurse up to 3 levels
#      • print the full path of the chosen file          (action=print)
#
#  Author : <your-name>
#  Version: 1.1  (2025-06-11)
###############################################################################
set -Eeuo pipefail

##############################  GLOBAL DEFAULTS  ##############################
# Search parameters
TARGETS=()                          # overridable with -t / --target
DEFAULT_TARGET="/usr/local/bin"     # used when TARGETS stays empty
RECURSIVE=true                      # recurse by default
MAX_DEPTH=3
EXTENSIONS=""                       # no filter → pick every executable

# Post-selection action
ACTION="print"                      # print | insert | exec
EXTRA_ARGS=""

# Visuals
THEME="Monokai Extended Bright"
WRAP="wrap"

###############################  BAT PRINTER  #################################
if command -v bat &>/dev/null; then
  BAT_PRINT=(bat --style="grid,header,snip" --squeeze-blank --strip-ansi \
                 --pager="less -R" --paging=never --tabs=2 --wrap=auto \
                 --italic-text=always --theme="$THEME")
  BAT_PREVIEW=(bat --style="grid,header,snip" --paging=never --terminal-width=-1 \
                  --strip-ansi --theme="$THEME")
else
  BAT_PRINT=(cat)
  BAT_PREVIEW=(cat)
fi

################################  USAGE  ######################################
usage() {
  "${BAT_PRINT[@]}" <<EOF
NAME
    fzf-script-picker – fuzzy-select an executable script and print / insert / run it.

SYNOPSIS
    fzf-script-picker [OPTIONS]

OPTIONS
    -t, --target <DIR1,DIR2,…>
           One or more directories to scan.  If omitted, defaults to
           ${DEFAULT_TARGET}.

    -r, --recursive [true|false]
           Recurse into sub-directories (default: true).  The value is
           optional; "-r false" disables recursion.

    -x, --extensions <EXTS>
           Restrict search to the comma/space separated list (e.g. sh,py).

    --action <print|insert|exec>
           What to do with the selection (default: print).

    --extra-args "<ARGS>"
           Extra arguments when --action exec.

    -h, --help
           Show this help and exit.

ENVIRONMENT
    BAT_THEME   Overrides the colour theme used by bat.

EOF
}

###########################  ARGUMENT PARSING  ################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)
      IFS=', ' read -r -a NEW <<< "${2:?--target needs a value}"
      TARGETS+=("${NEW[@]}"); shift 2;;
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
    --extra-args)
      EXTRA_ARGS=$2; shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown option: $1" >&2
      usage; exit 1;;
  esac
done

# If no targets supplied, fall back to /usr/local/bin
[[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=("$DEFAULT_TARGET")

# Sanity-check action
[[ $ACTION =~ ^(print|insert|exec)$ ]] || { echo "Invalid --action"; exit 1; }

# Need fzf
command -v fzf >/dev/null 2>&1 || { echo "fzf is required."; exit 1; }

#############################  FILE COLLECTION  ###############################
have() { command -v "$1" >/dev/null 2>&1; }

# Build extension filter for fd (or find)
EXT_FILTER=()
if [[ -n $EXTENSIONS ]]; then
  for e in $EXTENSIONS; do EXT_FILTER+=( -e "$e" ); done
fi

DEPTH_ARGS=()
[[ $RECURSIVE == true ]] || DEPTH_ARGS=(--max-depth "$MAX_DEPTH")

collect_files() {
  local dir=$1
  if have fd; then
    fd --type f --executable "${DEPTH_ARGS[@]}" \
       "${EXT_FILTER[@]}" --search-path "$dir"
  else
    local find_depth=""
    [[ $RECURSIVE != true ]] && find_depth="-maxdepth $MAX_DEPTH"
    find "$dir" $find_depth -type f -perm -u+x 2>/dev/null
  fi
}

mapfile -t CANDIDATES < <(
  for d in "${TARGETS[@]}"; do
    [[ -d $d ]] || { echo "⚠  '$d' is not a directory – skipped." >&2; continue; }
    collect_files "$d"
  done | sort -u
)

[[ ${#CANDIDATES[@]} -gt 0 ]] || { echo "No executable scripts found."; exit 1; }

###############################  FZF PICKER  ##################################
SELECTED=$(printf '%s\n' "${CANDIDATES[@]}" \
  | fzf --prompt="Scripts> " \
        --header="Choose a script to $ACTION" \
        --preview="${BAT_PREVIEW[*]} -- {}" \
        --preview-window=right:60%:$WRAP)

[[ -z $SELECTED ]] && exit 1          # user aborted

################################  ACTIONS  ####################################
case $ACTION in
  print)   printf '%s\n' "$SELECTED" ;;
  exec)    "$SELECTED" $EXTRA_ARGS ;;
  insert)
    if [[ -n ${ZSH_VERSION:-} ]]; then
      print -nz -- "$SELECTED "
    elif [[ -n ${BASH_VERSION:-} ]]; then
      READLINE_LINE=${READLINE_LINE:0:$READLINE_POINT}$SELECTED\ ${READLINE_LINE:$READLINE_POINT}
      READLINE_POINT=$(( READLINE_POINT + ${#SELECTED} + 1 ))
    else
      printf '%s\n' "$SELECTED"
    fi ;;
esac

