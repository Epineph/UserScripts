#!/usr/bin/env bash
#
# fzf-script-picker
# -----------------
# Fuzzy–find executable scripts in one or more folders,
# then either print, insert, or execute the selection.
#
###############################################################################
#  ░█▀▀░█▀█░█▀▄░█░█░█░█░▀█▀░█▀█            Author : Your-Name-Here
#  ░█░█░█░█░█▀▄░█░█░█░█░░█░░█░█            License: MIT
#  ░▀▀▀░▀▀▀░▀░▀░▀▀▀░▀▀▀░▀▀▀░▀▀▀            Version: 1.0.0
###############################################################################
#
#  USAGE EXAMPLES
#  --------------
#  fzf-script-picker -t /usr/local/bin
#  fzf-script-picker -t ~/bin -r -x "sh,py" --action insert
#  fzf-script-picker -t ~/bin --action exec --extra-args "--help"
#
###############################################################################
set -Eeuo pipefail

#############################  DEFAULT CONFIG  ################################
EDITOR="${EDITOR:-nvim}"          # Only used for help/preview if bat absent
THEME="Monokai Extended Bright"   # bat theme
WRAP="wrap"                       # fzf preview window setting

# Search behaviour
RECURSIVE=true                    # Recurse into sub-dirs by default
MAX_DEPTH=3                       # How deep to recurse when RECURSIVE=true
EXTENSIONS=""                     # Optional comma/space list of allowed ext.
TARGETS=()                        # One or more directories to scan

# Post-selection action (print | insert | exec)
ACTION="print"
EXTRA_ARGS=""                     # Extra args when ACTION=exec

#############################  HELPER FUNCTIONS  ##############################
die() { echo "[ERROR] $*" >&2; exit 1; }

usage() {
  cat <<EOF
fzf-script-picker – fuzzy-select executable scripts in a directory.

Options:
  -t, --target <DIR1,DIR2,…>   One or more folders to scan (repeatable).
  -r, --recursive [true|false] Recurse into sub-directories (default: $RECURSIVE).
  -x, --extensions <EXTS>      Comma/space list of allowed extensions (e.g. sh,py).
  --action <print|insert|exec> Post-selection behaviour (default: $ACTION).
  --extra-args "<ARGS>"        Extra arguments when --action exec.
  -h, --help                   Show this help.

Environment variables optionally honoured:
  BAT_THEME  Overrides --theme (bat only).

EOF
}

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required."; }
have() { command -v "$1" >/dev/null 2>&1; }

#############################  ARGUMENT PARSING  ##############################
while [[ $# -gt 0 ]]; do
  case $1 in
    -t|--target)
      IFS=', ' read -r -a NEW <<<"${2:?Missing value for --target}"; TARGETS+=("${NEW[@]}"); shift 2;;
    -r|--recursive) RECURSIVE=$2; shift 2;;
    -x|--extensions) EXTENSIONS="${2//,/ }"; shift 2;;
    --action) ACTION=$2; shift 2;;
    --extra-args) EXTRA_ARGS=$2; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done

[[ ${#TARGETS[@]} -eq 0 ]] && die "At least one --target directory is required."
[[ $ACTION =~ ^(print|insert|exec)$ ]] || die "--action must be print|insert|exec."

need fzf
have bat && BAT_PREVIEW=(bat --theme "${BAT_THEME:-$THEME}" --style=grid --paging=never) || BAT_PREVIEW=(cat)

[[ $RECURSIVE == true ]] && DEPTH_ARGS=() || DEPTH_ARGS=(--max-depth "$MAX_DEPTH")

#############################  FILE DISCOVERY  ################################
collect_files() {
  local dir=$1
  if have fd; then
    fd --type f --executable "${DEPTH_ARGS[@]}" "${EXT_FILTER[@]}" --search-path "$dir"
  else
    # POSIX find fallback (slower)
    local find_depth=""
    [[ $RECURSIVE != true ]] && find_depth="-maxdepth $MAX_DEPTH"
    find "$dir" $find_depth -type f -perm -u+x 2>/dev/null
  fi
}

# Build extension filter
EXT_FILTER=()
if [[ -n $EXTENSIONS ]]; then
  for e in $EXTENSIONS; do EXT_FILTER+=( -e "$e" ); done
fi

# Consolidate all candidate scripts
mapfile -t CANDIDATES < <(
  for d in "${TARGETS[@]}"; do
    [[ -d $d ]] || die "'$d' is not a directory."
    collect_files "$d"
  done | sort -u
)
(( ${#CANDIDATES[@]} == 0 )) && die "No executable scripts found."

#############################  FZF SELECTION  #################################
SELECTED=$(printf '%s\n' "${CANDIDATES[@]}" \
  | fzf --preview="${BAT_PREVIEW[*]} -- {}" --preview-window=right:60%:$WRAP \
        --prompt="Scripts> " --header="Choose a script to $ACTION" )

[[ -z $SELECTED ]] && exit 1         # User aborted

#############################  HANDLE ACTION  #################################
case $ACTION in
  print)   printf '%s\n' "$SELECTED" ;;
  exec)    "$SELECTED" $EXTRA_ARGS ;;
  insert)
    # Works both in zsh (via zle) and bash (via Readline)
    if [[ -n ${ZSH_VERSION:-} ]]; then
      print -nz -- "$SELECTED "
    elif [[ -n ${BASH_VERSION:-} ]]; then
      READLINE_LINE=${READLINE_LINE:0:$READLINE_POINT}$SELECTED\ ${READLINE_LINE:$READLINE_POINT}
      READLINE_POINT=$(( READLINE_POINT + ${#SELECTED} + 1 ))
    else
      printf '%s\n' "$SELECTED"
    fi
    ;;
esac

