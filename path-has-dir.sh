# Examples (expanded)
#
# NOTE ON PERSISTENCE:
#   Running this as a normal executable cannot permanently change the parent
#   shell’s PATH. To persist, use either:
#     - eval "$(path-has-dir ... --print-export)"
#     - source <(path-has-dir ... --print-export)
#
# ------------------------------------------------------------------------------
# 1) Check if ~/.local/bin is in PATH (print all positions)
# ------------------------------------------------------------------------------
path-has-dir ~/.local/bin
#
# Possible output:
#   IN PATH: /home/heini/.local/bin at position(s): 1 7
#   (duplicates are common; this reports them)

# ------------------------------------------------------------------------------
# 2) Check only the first position (useful if PATH is huge)
# ------------------------------------------------------------------------------
path-has-dir --first ~/.local/bin
#
# Possible output:
#   IN PATH (first): /home/heini/.local/bin at position 7

# ------------------------------------------------------------------------------
# 3) Check quietly (exit code only), typical for scripting
# ------------------------------------------------------------------------------
path-has-dir --quiet ~/.local/bin && echo "present" || echo "missing"
#
# Exit status:
#   0 -> present
#   1 -> missing

# ------------------------------------------------------------------------------
# 4) Print the raw matching PATH entries as they appear in $PATH
#    (helps debug ~ vs absolute, empty entries, weird quoting)
# ------------------------------------------------------------------------------
path-has-dir --show-path ~/.local/bin
#
# Example output:
#   IN PATH: /home/heini/.local/bin at position(s): 2
#     - position 2 raw entry: ~/.local/bin

# ------------------------------------------------------------------------------
# 5) Ensure present (prepend by default) for *this process only*
#    (useful inside a script that immediately runs tools from that dir)
# ------------------------------------------------------------------------------
path-has-dir --ensure ~/.local/bin --prepend
#
# This updates PATH *inside path-has-dir*, but not your interactive shell.
# So it is mainly useful if you source it or use --print-export + eval.

# ------------------------------------------------------------------------------
# 6) Ensure present and persist in current shell using eval
# ------------------------------------------------------------------------------
eval "$(path-has-dir --ensure ~/.local/bin --prepend --print-export)"
#
# After this, your current shell session has the updated PATH.

# ------------------------------------------------------------------------------
# 7) Ensure present and persist in current shell using source + process substitution
# ------------------------------------------------------------------------------
source <(path-has-dir --ensure ~/.local/bin --append --print-export)

# ------------------------------------------------------------------------------
# 8) Interactive default: no args
#    - checks $HOME/.local/bin
#    - if missing, prompts whether to add, and prepend vs append
# ------------------------------------------------------------------------------
path-has-dir

# ------------------------------------------------------------------------------
# 9) Interactive ensure for a specific directory
# ------------------------------------------------------------------------------
path-has-dir --ensure /opt/mytool/bin --prompt
#
# You will be asked:
#   "DIR not in PATH: /opt/mytool/bin. Add it? [y/N]:"
#   then:
#   "Prepend or append? [p/a] (default: prepend):"

# ------------------------------------------------------------------------------
# 10) Ensure append (persist) for a directory with spaces
#     (rare, but legal on Unix; this shows correct quoting)
# ------------------------------------------------------------------------------
eval "$(path-has-dir --ensure "$HOME/Applications/My Tool/bin" \
  --append --print-export)"

# ------------------------------------------------------------------------------
# 11) Compare ordering: check the effective search order for commands
#     Example: if you have multiple Python installs, PATH position matters.
# ------------------------------------------------------------------------------
path-has-dir --first /usr/local/bin
path-has-dir --first /usr/bin
path-has-dir --first "$HOME/.local/bin"

# ------------------------------------------------------------------------------
# 12) Remove duplicates (workflow example; this script does not remove them)
#     Use output positions to decide what to clean in your shell rc files.
# ------------------------------------------------------------------------------
path-has-dir --show-path "$HOME/.local/bin"
#
# If you see it at multiple positions, you likely export it multiple times in
# different init files (e.g., both .zprofile and .zshrc, or multiple fragments).

# ------------------------------------------------------------------------------
# 13) Use it inside another script (pattern)
# ------------------------------------------------------------------------------
if ! path-has-dir --quiet "$HOME/.local/bin"; then
  # This adds it for the current script's environment if you choose to source it:
  eval "$(path-has-dir --ensure "$HOME/.local/bin" --prepend --print-export)"
fi
#
# Now the remainder of your script can rely on tools living in ~/.local/bin.

# ------------------------------------------------------------------------------
# 14) Ensure a dir is present *only if it exists* (guard pattern)
# ------------------------------------------------------------------------------
d="$HOME/.cargo/bin"
if [[ -d "$d" ]]; then
  eval "$(path-has-dir --ensure "$d" --prepend --print-export)"
fi

# ------------------------------------------------------------------------------
# 15) Debug PATH issues caused by empty entries meaning "."
#     (PATH=":/usr/bin" means current directory is first)
# ------------------------------------------------------------------------------
# This reports empty entries correctly; try:
PATH=":/usr/bin" path-has-dir --show-path .


set -euo pipefail

function usage() {
  cat <<'EOF'
Usage:
  path-has-dir [OPTIONS] [DIR]

Primary modes:
  (1) Check:
      path-has-dir DIR
  (2) Ensure present (non-interactive):
      path-has-dir --ensure DIR [--prepend|--append]
  (3) Ensure present (interactive default if DIR omitted):
      path-has-dir

Options:
  -a, --all           Print all positions where DIR appears in $PATH (default).
  -f, --first         Print only the first position (if present).
  -q, --quiet         Print nothing; use exit code only.
  -p, --show-path     Also print matching PATH entry(ies) as stored in $PATH.

  -e, --ensure        If DIR is missing, add it (in this process) and report.
                      For persistence: use --print-export and eval/source.

  --prepend           When ensuring, add DIR to the front (default).
  --append            When ensuring, add DIR to the end.

  --prompt            If DIR is missing, prompt whether to add, and where.
                      (Only meaningful in ensure mode; auto-enabled when no args.)
  --no-prompt         Never prompt (default in ensure mode unless --prompt used).

  --print-export      Print a shell snippet:  export PATH='...'
                      Suitable for: eval "$(path-has-dir ... --print-export)"

  -h, --help          Show help.

Examples:
  path-has-dir ~/.local/bin
  path-has-dir --ensure ~/.local/bin --prepend
  eval "$(path-has-dir --ensure ~/.local/bin --append --print-export)"
  source <(path-has-dir --ensure ~/.local/bin --prepend --print-export)
EOF
}

function norm_abs_path() {
  local in="$1"

  if [[ "$in" == "~" ]]; then
    in="$HOME"
  elif [[ "$in" == "~/"* ]]; then
    in="$HOME/${in#~/}"
  fi

  if [[ "$in" != /* ]]; then
    in="$PWD/$in"
  fi

  while [[ "$in" != "/" && "$in" == */ ]]; do
    in="${in%/}"
  done

  local -a parts out
  IFS='/' read -r -a parts <<<"$in"
  for part in "${parts[@]}"; do
    case "$part" in
      ""|".") continue ;;
      "..")
        if ((${#out[@]} > 0)); then
          unset 'out[${#out[@]}-1]'
        fi
        ;;
      *) out+=("$part") ;;
    esac
  done

  local result="/"
  if ((${#out[@]} > 0)); then
    result="/$(IFS='/'; echo "${out[*]}")"
  fi
  printf '%s\n' "$result"
}

function split_path() {
  # Outputs PATH entries (raw) as array via global PATH_ENTRIES.
  local p="${PATH-}"
  IFS=':' read -r -a PATH_ENTRIES <<<"$p"
}

function find_matches() {
  # Inputs:
  #   $1 target_norm
  # Outputs globals:
  #   MATCH_POS (1-based positions), MATCH_RAW (raw entries)
  local target_norm="$1"
  MATCH_POS=()
  MATCH_RAW=()

  split_path
  for i in "${!PATH_ENTRIES[@]}"; do
    local entry="${PATH_ENTRIES[$i]}"
    local comp="$entry"
    [[ -z "$comp" ]] && comp="."
    local entry_norm
    entry_norm="$(norm_abs_path "$comp")"
    if [[ "$entry_norm" == "$target_norm" ]]; then
      MATCH_POS+=("$((i + 1))")
      MATCH_RAW+=("$entry")
    fi
  done
}

function ensure_in_path() {
  # Inputs:
  #   $1 target_raw (as user typed)
  #   $2 where: "prepend" or "append"
  #
  # Uses normalization to avoid duplicates.
  local target_raw="$1"
  local where="$2"

  local target_norm
  target_norm="$(norm_abs_path "$target_raw")"
  find_matches "$target_norm"

  if ((${#MATCH_POS[@]} > 0)); then
    ENSURE_CHANGED=0
    return 0
  fi

  local target_for_path="$target_norm"

  if [[ "$where" == "prepend" ]]; then
    if [[ -z "${PATH-}" ]]; then
      PATH="$target_for_path"
    else
      PATH="$target_for_path:$PATH"
    fi
  else
    if [[ -z "${PATH-}" ]]; then
      PATH="$target_for_path"
    else
      PATH="$PATH:$target_for_path"
    fi
  fi

  ENSURE_CHANGED=1
}

function prompt_yes_no() {
  # $1 prompt text
  local prompt="$1"
  local ans=""
  while true; do
    read -r -p "$prompt [y/N]: " ans || return 1
    ans="${ans,,}"
    case "$ans" in
      y|yes) return 0 ;;
      n|no|"") return 1 ;;
      *) printf 'Please answer y or n.\n' >&2 ;;
    esac
  done
}

function prompt_where() {
  # Prints "prepend" or "append"
  local ans=""
  while true; do
    read -r -p "Prepend or append? [p/a] (default: prepend): " ans || {
      printf '%s\n' "prepend"
      return 0
    }
    ans="${ans,,}"
    case "$ans" in
      p|pre|prepend|"") printf '%s\n' "prepend"; return 0 ;;
      a|app|append)     printf '%s\n' "append"; return 0 ;;
      *) printf 'Please answer p or a.\n' >&2 ;;
    esac
  done
}

# ------------------------------ Defaults ------------------------------
mode="check"         # "check" or "ensure"
print_mode="all"     # "all" or "first"
quiet=0
show_path=0
where="prepend"
prompt=0
print_export=0

# If invoked with no args: interactive ensure for ~/.local/bin (common case).
default_dir="$HOME/.local/bin"

# ------------------------------ Parse args ------------------------------
args=()

while (($#)); do
  case "$1" in
    -a|--all) print_mode="all"; shift ;;
    -f|--first) print_mode="first"; shift ;;
    -q|--quiet) quiet=1; shift ;;
    -p|--show-path) show_path=1; shift ;;

    -e|--ensure) mode="ensure"; shift ;;
    --prepend) where="prepend"; shift ;;
    --append) where="append"; shift ;;

    --prompt) prompt=1; shift ;;
    --no-prompt) prompt=0; shift ;;

    --print-export) print_export=1; shift ;;

    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) printf 'Error: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

# Remaining after "--"
while (($#)); do
  args+=("$1"); shift
done

# Auto interactive ensure when no args and not explicitly in check mode.
if ((${#args[@]} == 0)); then
  mode="ensure"
  prompt=1
  args=("$default_dir")
fi

if ((${#args[@]} != 1)); then
  usage >&2
  exit 2
fi

dir_in="${args[0]}"
target_norm="$(norm_abs_path "$dir_in")"

# ------------------------------ Check ------------------------------
find_matches "$target_norm"

present=0
if ((${#MATCH_POS[@]} > 0)); then
  present=1
fi

# ------------------------------ Ensure (optional) ------------------------------
if [[ "$mode" == "ensure" && $present -eq 0 ]]; then
  local_where="$where"

  if ((prompt)); then
    if prompt_yes_no "DIR not in PATH: $target_norm. Add it?"; then
      local_where="$(prompt_where)"
    else
      ((quiet)) || printf 'Not added.\n'
      exit 1
    fi
  fi

  ENSURE_CHANGED=0
  ensure_in_path "$dir_in" "$local_where"

  # Recompute matches for reporting.
  find_matches "$target_norm"
  present=1
fi

# ------------------------------ Output ------------------------------
if ((present == 0)); then
  ((quiet)) || printf 'NOT IN PATH: %s\n' "$target_norm"
  exit 1
fi

if ((quiet)); then
  if ((print_export)); then
    # Quiet + print-export is contradictory; still print export if asked.
    :
  else
    exit 0
  fi
fi

if ((print_export)); then
  # For eval/source use. Use %q to safely quote.
  printf "export PATH=%q\n" "$PATH"
  exit 0
fi

if [[ "$print_mode" == "first" ]]; then
  if ((show_path)); then
    printf 'IN PATH (first): %s at position %s (raw entry: %q)\n' \
      "$target_norm" "${MATCH_POS[0]}" "${MATCH_RAW[0]}"
  else
    printf 'IN PATH (first): %s at position %s\n' \
      "$target_norm" "${MATCH_POS[0]}"
  fi
else
  if ((show_path)); then
    printf 'IN PATH: %s at position(s): %s\n' \
      "$target_norm" "${MATCH_POS[*]}"
    for j in "${!MATCH_POS[@]}"; do
      printf '  - position %s raw entry: %q\n' \
        "${MATCH_POS[$j]}" "${MATCH_RAW[$j]}"
    done
  else
    printf 'IN PATH: %s at position(s): %s\n' \
      "$target_norm" "${MATCH_POS[*]}"
  fi
fi

exit 0
