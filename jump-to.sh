#!/usr/bin/env bash
# jump-to — Navigate to paths resolved from ENV names or explicit paths, with optional search & actions.
# Requires: bash 4+, optional: fd (fdfind), fzf
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.2.0"

# ─────────────────────────── Utilities ───────────────────────────
function have()
{
  command -v "$1" > /dev/null 2>&1
}

function die()
{
  printf 'jump-to: %s\n' "$*" >&2
  exit 1
}

function info()
{
  printf 'jump-to: %s\n' "$*" >&2
}

function default_editor()
{
  if [[ -n "${EDITOR:-}" ]]; then
    printf '%s\n' "$EDITOR"
    return
  fi
  for e in nvim vim nano vi; do
    have "$e" && {
      printf '%s\n' "$e"
      return
    }
  done
  printf '%s\n' "vi"
}

# Map comma-separated type tokens -> extensions list
# Accepts forms like: py,.py,sh,.sh,ps1,.ps1,R,.R,md,.md,txt
function map_types()
{
  local raw="$1" tok ext
  local -a out=()
  # split on commas
  while IFS=, read -r tok; do
    tok="${tok// /}"
    [[ -z "$tok" ]] && continue
    tok="${tok#.}" # drop leading dot
    case "$tok" in
      sh)
        out+=(sh)
        ;;
      py)
        out+=(py)
        ;;
      ps1)
        out+=(ps1)
        ;;
      r | R)
        out+=(R r)
        ;;
      md | markdown)
        out+=(md markdown)
        ;;
      txt)
        out+=(txt)
        ;;
      json)
        out+=(json)
        ;;
      toml)
        out+=(toml)
        ;;
      yml | yaml)
        out+=(yml yaml)
        ;;
      *)
        out+=($tok)
        ;; # treat as literal extension
    esac
  done <<< "$raw"
  printf '%s\n' "${out[@]}"
}

# Print numbered menu if fzf not present
function choose_with_menu()
{
  local -a items=("$@")
  local i=1
  for it in "${items[@]}"; do
    printf '%2d) %s\n' "$i" "$it" >&2
    ((i++))
  done
  local choice
  read -rp "Select [1-${#items[@]}]: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] \
    || return 1
  ((choice >= 1 && choice <= ${#items[@]})) \
    || return 1
  printf '%s\n' "${items[choice - 1]}"
}

# Replace {} with path or append path at end
function build_exec_cmd()
{
  local template="$1" target="$2"
  if [[ "$template" == *"{}"* ]]; then
    # shellcheck disable=SC2001
    printf '%s\n' "$(sed "s|{}|$target|g" <<< "$template")"
  else
    printf '%s %s\n' "$template" "$target"
  fi
}

# ─────────────────────────── Help ───────────────────────────
function show_help()
{
  cat << 'EOF'
jump-to — Navigate to a base directory (ENV or PATH), 
          optionally search inside it, and run commands.

USAGE
  jump-to [ENV_NAME | -p PATH] [SUBPATH] [OPTIONS]

BASE RESOLUTION
  • ENV_NAME         Environment variable *name* without '$', 
                     e.g.  jump-to MY_REPOS
                     (equivalent of: cd "$MY_REPOS").
  • -p, --path PATH  Use an explicit path as the base (file or directory).

  • SUBPATH          Optional relative subdirectory under the base,
                     e.g. "UserScripts/wrappers".
  Notes:
    - If PATH is a file, the base is its directory 
      and the file becomes the initial selection.

    - If both ENV_NAME and -p are given, -p wins.

SEARCH / FILTER
  -n, --name NAME            Exact basename match (files or directories). 
                             If duplicates, an interactive picker is shown 
                             (fzf if available, else a numbered menu).

  -f, --fzf, --fuzzy-finding Enable fuzzy selection over found matches 
                             (always used if multiple matches
                             and fzf is installed, or when -x/--execute 
                             is supplied and ambiguous).

  -t, --file-type LIST       Comma-separated extension filters, 
                             e.g. "py,sh,md" or ".py,.sh".
                             Examples: py, sh, ps1, R, md, txt,
                             json, yml, yaml (case-insensitive).
                             
                             If provided *alone*, you must also supply -r or -d.

  -r, --recursion            Recurse fully unless limited by -d.

  -d, --depth N              Limit recursion depth; implies recursion when present.
                             (depth=1 inspects immediate children only; 
                             depth=0 is the base itself.)

ACTION / EXECUTION
  -x, --execute CMD          Run CMD on the chosen target.
                               • '{}' in CMD is replaced with the path.

                               • If '{}' is absent and a file is selected, 
                                 the path is appended to CMD.

                               • If target is a directory, 
                                 CMD runs in that directory with no arguments.

  -e, --editor EDITOR        Editor to use for files when -x is not provided 
                             (defaults to $EDITOR or nvim|vim|nano|vi).

  -j, --jump-to              Drop into a subshell at the final directory 
                             (to "stay" there interactively).
                             Exit the subshell to return to your original shell.

OUTPUT
  • On success, prints the final resolved path to STDOUT (useful for: cd "$(jump-to …)").

EXAMPLES
  # Jump to $MY_REPOS
  jump-to MY_REPOS

  # Jump to $MY_REPOS/UserScripts/wrappers
  jump-to MY_REPOS UserScripts/wrappers

  # Using an explicit path instead of an ENV
  jump-to -p ~/my_repos UserScripts

  # Find an exact name under $MY_REPOS with full recursion; if many, pick via fzf
  jump-to MY_REPOS -n device-mapper.py -r

  # Limit recursion to depth=2 and filter file types
  jump-to MY_REPOS -t py,md -d 2

  # Fuzzy-pick among all files under the base and open in editor
  jump-to MY_REPOS -f -r

  # Execute a command on the chosen file (path substituted with {})
  jump-to MY_REPOS -r -n chPerms.sh -x "bat --style=grid {}"

  # Execute in the directory if a directory is selected, then subshell there
  jump-to -p ~/my_repos/UserScripts -x "ls -la" -j

  # Script integration: change directory in your current shell
  cd "$(jump-to MY_REPOS UserScripts)"
EOF
}

# ─────────────────────────── Defaults ───────────────────────────
BASE_PATH=""
ENV_NAME=""
SUBPATH=""
NAME_EXACT=""
FUZZY=false
DEPTH=""
RECURSE=false
FILETYPES_RAW=""
EXEC_CMD=""
EDITOR_CMD="$(default_editor)"
SUBSHELL=false
PRINT_ONLY=false # future flag if needed
ORIG_PWD="$(pwd)"

# ─────────────────────────── Parse args ───────────────────────────
if (($# == 0)); then
  show_help
  exit 1
fi

while (($#)); do
  case "$1" in
    -h | --help)
      show_help
      exit 0
      ;;
    --version)
      echo "jump-to $VERSION"
      exit 0
      ;;
    -p | --path)
      [[ $# -ge 2 ]] || die "missing argument for $1"
      BASE_PATH="$2"
      shift 2
      ;;
    -n | --name)
      [[ $# -ge 2 ]] || die "missing argument for $1"
      NAME_EXACT="$2"
      shift 2
      ;;
    -f | --fzf | --fuzzy-finding)
      FUZZY=true
      shift
      ;;
    -t | --file-type)
      [[ $# -ge 2 ]] || die "missing argument for $1"
      FILETYPES_RAW="$2"
      shift 2
      ;;
    -r | --recursion)
      RECURSE=true
      shift
      ;;
    -d | --depth)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] \
        || die "depth must be a non-negative integer"
      DEPTH="$2"
      RECURSE=true
      shift 2
      ;;
    -x | --execute)
      [[ $# -ge 2 ]] || die "missing argument for $1"
      EXEC_CMD="$2"
      shift 2
      ;;
    -e | --editor)
      [[ $# -ge 2 ]] || die "missing argument for $1"
      EDITOR_CMD="$2"
      shift 2
      ;;
    -j | --jump-to)
      SUBSHELL=true
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      # First non-option token that isn't consumed by -p/--path is either
      # ENV_NAME or SUBPATH (if -p already set and ENV_NAME empty)
      if [[ -z "$ENV_NAME" && -z "$BASE_PATH" ]]; then
        ENV_NAME="$1"
      elif [[ -z "$SUBPATH" ]]; then
        SUBPATH="$1"
      else
        # Allow spaces inside SUBPATH if given as multiple tokens
        SUBPATH="$SUBPATH $1"
      fi
      shift
      ;;
  esac
done

# Remaining tokens after -- are treated as SUBPATH continuation (optional)
if (($#)); then
  SUBPATH="${SUBPATH:+$SUBPATH }$*"
fi

# ─────────────────────────── Resolve base ───────────────────────────
if [[ -n "$ENV_NAME" && -n "$BASE_PATH" ]]; then
  info "both ENV_NAME '$ENV_NAME' and --path supplied; using --path"
fi

if [[ -z "$BASE_PATH" ]]; then
  if [[ -z "$ENV_NAME" ]]; then
    die "no ENV_NAME or --path provided. See --help."
  fi
  # ENV name without leading $
  ENV_NAME="${ENV_NAME#\$}"
  [[ "$ENV_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || die "invalid ENV name: '$ENV_NAME'"
  if eval "[[ -n \${$ENV_NAME+x} ]]"; then
    eval "BASE_PATH=\${$ENV_NAME}"
  else
    die "environment variable '$ENV_NAME' is not set"
  fi
fi

# Expand ~ and normalize
BASE_PATH="${BASE_PATH/#\~/$HOME}"

# If BASE_PATH is a file, keep it as initial selection and base becomes its directory
INITIAL_FILE=""
if [[ -f "$BASE_PATH" ]]; then
  INITIAL_FILE="$(basename -- "$BASE_PATH")"
  BASE_PATH="$(dirname -- "$BASE_PATH")"
fi

# Apply SUBPATH if any
if [[ -n "$SUBPATH" ]]; then
  # sanitize leading/trailing slashes
  SUBPATH="${SUBPATH#/}"
  SUBPATH="${SUBPATH%/}"
  BASE_PATH="$BASE_PATH/$SUBPATH"
fi

# Normalize base
if have realpath; then
  BASE_PATH="$(realpath -m -- "$BASE_PATH" 2> /dev/null || echo "$BASE_PATH")"
fi

[[ -d "$BASE_PATH" ]] \
  || die "base path is not a directory: $BASE_PATH"

# ───────────────── Search plan & execution ─────────────────
# If NONE of (-n, -f, -t, -r/-d, -x) are provided → simple jump
# (print base and optional subshell)

simple_jump=true

[[ -n "$NAME_EXACT" ||
  "$FUZZY" = true ||
  -n "$FILETYPES_RAW" ||
  -n "$DEPTH" ||
  "$RECURSE" = true ||
  -n "$EXEC_CMD" ]] && simple_jump=false

if [[ "$simple_jump" = true ]]; then
  printf '%s\n' "$BASE_PATH"
  if [[ "$SUBSHELL" = true ]]; then
    (cd -- "$BASE_PATH" && exec "${SHELL:-/bin/bash}")
  fi
  exit 0
fi

# If -t provided alone without recursion hints → error (per your spec)
if [[ -n "$FILETYPES_RAW" && ! "$RECURSE" && -z "$DEPTH" && -z "$NAME_EXACT" && ! "$FUZZY" ]]; then
  die "-t/--file-type requires -r or -d when used alone"
fi

# Build extension filters
declare -a EXTS=()
if [[ -n "$FILETYPES_RAW" ]]; then
  # shellcheck disable=SC2207
  EXTS=($(map_types "$FILETYPES_RAW"))
fi

# Find candidates
declare -a CANDIDATES=()

use_fd=false
if have fd; then
  use_fd=true
elif have fdfind; then
  use_fd=true
  alias fd=fdfind > /dev/null 2>&1 || true
fi

if [[ -n "$INITIAL_FILE" ]]; then
  # Seed initial candidate if base was a file path
  CANDIDATES+=("$(printf '%s/%s' "$BASE_PATH" "$INITIAL_FILE")")
fi

# Helper to add candidates (unique)
function add_candidates()
{
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    CANDIDATES+=("$line")
  done
}

# fd matches basename by default; anchor regex for exact match depth
# Exact name search (-n)
if [[ -n "$NAME_EXACT" ]]; then
  if "$use_fd"; then
    local_fd=$(fd --hidden --follow --color=never --regex "^${NAME_EXACT}\$" "$BASE_PATH")
    if [[ -n "$DEPTH" ]]; then
      local_fd+=(--max-depth "$DEPTH")
    elif [[ "$RECURSE" = false ]]; then
      local_fd+=(--max-depth 1)
    fi
    add_candidates <<< "$("${local_fd[@]}" 2> /dev/null || true)"
  else
    # find exact basename
    if [[ -n "$DEPTH" ]]; then
      add_candidates <<< "$(find "$BASE_PATH" -maxdepth "$DEPTH" -name "$NAME_EXACT" -print 2> /dev/null || true)"
    elif [[ "$RECURSE" = false ]]; then
      add_candidates <<< "$(find "$BASE_PATH" -maxdepth 1 -name "$NAME_EXACT" -print 2> /dev/null || true)"
    else
      add_candidates <<< "$(find "$BASE_PATH" -name "$NAME_EXACT" -print 2> /dev/null || true)"
    fi
  fi
fi

# File type filter (-t), default to files only
if [[ ${#EXTS[@]} -gt 0 ]]; then
  if "$use_fd"; then
    local_fd=(fd --hidden --follow --color=never -t f . "$BASE_PATH")
    if [[ -n "$DEPTH" ]]; then
      local_fd+=(--max-depth "$DEPTH")
    elif [[ "$RECURSE" = false ]]; then
      local_fd+=(--max-depth 1)
    fi
    for ext in "${EXTS[@]}"; do
      local_fd+=(-e "$ext")
    done
    add_candidates <<< "$("${local_fd[@]}" 2> /dev/null || true)"
  else
    # build -name clauses
    local_find=(find "$BASE_PATH")
    if [[ -n "$DEPTH" ]]; then
      local_find+=(-maxdepth "$DEPTH")
    elif [[ "$RECURSE" = false ]]; then
      local_find+=(-maxdepth 1)
    fi
    local_find+=(\()
    local first=1
    for ext in "${EXTS[@]}"; do
      if ((first)); then
        local_find+=(-type f -iname "*.${ext}")
        first=0
      else
        local_find+=(-o -type f -iname "*.${ext}")
      fi
    done
    local_find+=(\) -print)
    add_candidates <<< "$("${local_find[@]}" 2> /dev/null || true)"
  fi
fi

# Fuzzy mode (-f) without constraints → list all files (not dirs) under base
if [[ "$FUZZY" = true && -z "$NAME_EXACT" && ${#EXTS[@]} -eq 0 ]]; then
  if "$use_fd"; then
    local_fd=(fd --hidden --follow --color=never -t f . "$BASE_PATH")
    if [[ -n "$DEPTH" ]]; then
      local_fd+=(--max-depth "$DEPTH")
    elif [[ "$RECURSE" = false ]]; then
      local_fd+=(--max-depth 1)
    fi
    add_candidates <<< "$("${local_fd[@]}" 2> /dev/null || true)"
  else
    local_find=(find "$BASE_PATH" -type f -print)
    if [[ -n "$DEPTH" ]]; then
      local_find=(find "$BASE_PATH" -type f -maxdepth "$DEPTH" -print)
    elif [[ "$RECURSE" = false ]]; then
      local_find=(find "$BASE_PATH" -type f -maxdepth 1 -print)
    fi
    add_candidates <<< "$("${local_find[@]}" 2> /dev/null || true)"
  fi
fi

# If no candidates were produced but we had INITIAL_FILE (from -p file) ⇒ keep it
# Else if still empty and no search flags other than -x were given: use base itself.
if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  if [[ -n "$EXEC_CMD" && -z "$NAME_EXACT" && -z "$FILETYPES_RAW" && ! "$FUZZY" ]]; then
    # Execute against the base directory
    CANDIDATES+=("$BASE_PATH")
  fi
fi

# De-duplicate candidates
if ((${#CANDIDATES[@]} > 0)); then
  mapfile -t CANDIDATES < <(printf '%s\n' "${CANDIDATES[@]}" | awk '!seen[$0]++')
fi

# Decide selection
SELECTED=""
if ((${#CANDIDATES[@]} == 0)); then
  # If no search constraints, fall back to base
  if [[ -z "$NAME_EXACT" && ${#EXTS[@]} -eq 0 && ! "$FUZZY" ]]; then
    SELECTED="$BASE_PATH"
  else
    die "no matches found under: $BASE_PATH"
  fi
elif ((${#CANDIDATES[@]} == 1)); then
  SELECTED="${CANDIDATES[0]}"
else
  # Multiple: prefer fzf if present or if --fzf set; else numbered menu
  if have fzf; then
    info "multiple matches; launching fzf"
    SELECTED="$(printf '%s\n' "${CANDIDATES[@]}" | fzf --no-multi --prompt="jump-to> " --height=80% || true)"
    [[ -n "$SELECTED" ]] || die "selection cancelled"
  else
    info "multiple matches; fzf not found → using numbered menu"
    SELECTED="$(choose_with_menu "${CANDIDATES[@]}")" || die "selection cancelled"
  fi
fi

# Determine final directory to cd/operate in, and the file (if any)
FINAL_DIR="$BASE_PATH"
TARGET_ITEM="$SELECTED"

if [[ -d "$TARGET_ITEM" ]]; then
  FINAL_DIR="$TARGET_ITEM"
else
  FINAL_DIR="$(dirname -- "$TARGET_ITEM")"
fi

# ───────────────── Execute or open ─────────────────
# Always print the final directory path to stdout at the very end.
function perform()
{
  local cmd="$1" item="$2" dir="$3"
  # Go to dir and run
  pushd "$dir" > /dev/null || die "failed to enter: $dir"
  if [[ -z "$cmd" ]]; then
    popd > /dev/null || true
    return 0
  fi
  local line
  if [[ -f "$item" ]]; then
    # Build command with file operand
    local rel="${item#$dir/}" # relative for prettier cmdline
    line="$(build_exec_cmd "$cmd" "$(printf '%q' "$rel")")"
  else
    # Directory target: run command in the directory without extra args
    line="$cmd"
  fi
  info "exec: $line"
  # shellcheck disable=SC2086
  bash -lc "$line"
  local rc=$?
  popd > /dev/null || true
  return $rc
}

# If -x given → execute; else if selected is a file → use editor; else just emit path
if [[ -n "$EXEC_CMD" ]]; then
  perform "$EXEC_CMD" "$TARGET_ITEM" "$FINAL_DIR"
elif [[ -f "$TARGET_ITEM" ]]; then
  perform "$EDITOR_CMD" "$TARGET_ITEM" "$FINAL_DIR"
fi

# Emit final path (stdout)
printf '%s\n' "$FINAL_DIR"

# Optional subshell to "stay" there interactively
if [[ "$SUBSHELL" = true ]]; then
  (cd -- "$FINAL_DIR" && exec "${SHELL:-/bin/bash}")
fi

exit 0
