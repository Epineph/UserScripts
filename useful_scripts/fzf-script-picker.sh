#!/usr/bin/env bash
###############################################################################
# fzf-script-picker  v1.6 – 2025-06-13
#
#  • Fuzzy-find executable scripts by name.
#  • Preview window shows full file with Bash syntax highlighting.
#  • Defaults: scan /usr/local/bin, recurse 3 levels, insert the name.
#  • --exec: run the chosen script (full path) with any extra args.
###############################################################################
set -Eeuo pipefail

##### 1) GLOBAL DEFAULTS ######################################################
DEFAULT_TARGET="/usr/local/bin"
TARGETS=()
RECURSIVE=true
MAX_DEPTH=3
EXTENSIONS=""
ACTION="insert"      # insert | print | exec
EXTRA_ARGS=""
THEME="Monokai Extended Bright"
WRAP="wrap"

##### 2) BAT VS CAT FOR HELP & PREVIEW #########################################
if command -v bat &>/dev/null; then
  BAT_PRINT=(bat --style="grid,header,snip" \
                 --strip-ansi=always --squeeze-blank \
                 --pager="less -R" --paging=never \
                 --tabs=2 --wrap=auto \
                 --italic-text=always --theme="$THEME")
  # ← Here we add --language=bash so every preview is highlighted as shell
  BAT_PREVIEW=(bat --language=bash --style="grid,header,snip" \
                   --strip-ansi=always --paging=never \
                   --terminal-width=-1 --theme="$THEME")
else
  BAT_PRINT=(cat)
  BAT_PREVIEW=(cat)
fi

##### 3) USAGE ###############################################################
usage() {
  "${BAT_PRINT[@]}" <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -t, --target <DIR1,DIR2…>   Scan these folders (default: $DEFAULT_TARGET).
  -r, --recursive [true|false] Recurse? (default: true; "-r false" disables).
  -x, --extensions <exts>      Comma/space list to filter (e.g. sh,py).
  --action <insert|print|exec> What to do (default: insert).
  --exec                       Shortcut for --action exec.
  --extra-args "<ARGS>"        Arguments when using --exec.
  -h, --help                   This help.

ENVIRONMENT
  BAT_THEME Overrides the bat theme.
EOF
}

##### 4) ARGUMENT PARSING ####################################################
while [[ $# -gt 0 ]]; do
  case $1 in
    -t|--target)
      IFS=', ' read -r -a more <<<"${2:?--target needs a value}"
      TARGETS+=("${more[@]}"); shift 2;;
    -r|--recursive)
      if [[ $# -ge 2 && $2 != -* ]]; then RECURSIVE=$2; shift 2
      else RECURSIVE=true; shift; fi;;
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

# default to /usr/local/bin
(( ${#TARGETS[@]} == 0 )) && TARGETS=("$DEFAULT_TARGET")
[[ $ACTION =~ ^(insert|print|exec)$ ]] || { echo "Invalid --action"; exit 1; }
command -v fzf >/dev/null 2>&1 || { echo "fzf is required"; exit 1; }

##### 5) COLLECT EXECUTABLE FILES #############################################
have() { command -v "$1" &>/dev/null; }

EXT_FILTER=()
[[ -n $EXTENSIONS ]] && for e in $EXTENSIONS; do EXT_FILTER+=( -e "$e" ); done

DEPFLAGS=()
[[ $RECURSIVE != true ]] && DEPFLAGS=( --max-depth "$MAX_DEPTH" )

collect_files() {
  local d=$1
  if have fd; then
    fd --type f "${DEPFLAGS[@]}" "${EXT_FILTER[@]}" --search-path "$d"
  else
    local md=""
    [[ $RECURSIVE != true ]] && md="-maxdepth $MAX_DEPTH"
    find "$d" $md -type f 2>/dev/null
  fi
}

# Build "<basename><TAB><fullpath>" lines and filter executables
mapfile -t RAW_LIST < <(
  for d in "${TARGETS[@]}"; do
    [[ -d $d ]] || { echo "⚠ '$d' not a directory; skipping." >&2; continue; }
    collect_files "$d"
  done | while IFS= read -r f; do
      [[ -x $f ]] && printf '%s\t%s\n' "$(basename "$f")" "$f"
    done | sort -u
)
(( ${#RAW_LIST[@]} )) || { echo "No executable scripts found."; exit 1; }

##### 6) FUZZY-SELECT #########################################################
SELECTED_LINE=$(printf '%s\n' "${RAW_LIST[@]}" \
  | fzf --prompt="Scripts> " \
        --header="Choose script → $ACTION" \
        --delimiter=$'\t' \
        --with-nth=1 \
        --preview="cut -f2 <<< {} | xargs -d'\n' ${BAT_PREVIEW[*]} --" \
        --preview-window=right:60%:$WRAP)

[[ -z $SELECTED_LINE ]] && exit 1

SCRIPT_NAME=${SELECTED_LINE%%$'\t'*}
SCRIPT_PATH=${SELECTED_LINE#*$'\t'}

##### 7) POST-SELECTION ######################################################
case $ACTION in
  exec)
    exec "$SCRIPT_PATH" $EXTRA_ARGS ;;
  print|insert)
    # both modes simply emit the name; your shell widget can insert it
    printf '%s\n' "$SCRIPT_NAME" ;;
esac

