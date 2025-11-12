#!/usr/bin/env bash
# yay-resolver — conflict-aware, selection-capable installer for yay/pacman
# Modes:
#   1) Explicit targets (-S/--): run conflict-aware install for the given packages.
#   2) Search mode (no -S): run `yay -Ss <terms>`, enumerate candidates, select via --pick/--first/--match/--exact, then install.
#
# Safety: conflict detection happens in a non-install probe; actual changes occur only after a plan is decided.
# Language: force C for parse stability.

set -euo pipefail
LANG=C

YAY_BIN="${YAY_BIN:-yay}"
PACMAN_BIN="${PACMAN_BIN:-pacman}"

print_help() {
cat <<'EOF'
Usage:
  # Explicit targets (as before)
  yay-resolver [OPTIONS] -- <pkg1> [<pkg2>...]
  yay-resolver [OPTIONS] -S <pkg1> [<pkg2>...]

  # Search mode (omit -S): terms + selection flags
  yay-resolver [OPTIONS] <search terms...> [--pick "1 3"] [--first N] [--match REGEX] [--exact NAME[,NAME2,...]] [--needed ...]

Purpose:
  Install packages with yay while handling package conflicts non-interactively.
  Also supports a 'menu-search' workflow when -S is omitted (like `yay smtp --needed`), but without interactive TUI:
    • Enumerate candidates from `yay -Ss`.
    • Select deterministically (indices, regex, first N, exact names).
    • Apply conflict resolution policy.
    • Proceed with reproducible commands.

Conflict policy:
  --resolve-conflict {yes|no|prompt}
      yes    : remove installed blocker(s) via 'pacman -Rns --noconfirm' then install.
      no     : skip the conflicting target(s) and continue.
      prompt : ask per conflict (default).

  --skip-conflicts
      Alias for: --resolve-conflict no

  --prefer {installed|target|first|pkg=<name>}
      When two *requested targets* conflict:
        installed : keep the one already installed (default).
        target    : prefer the one explicitly requested (if only one of the two is).
        first     : keep whichever appears first in your requested list.
        pkg=<nm>  : force this package to win.

Search-mode selection (takes effect only if -S/-- not used):
  --pick "IDX [IDX2 ...]"
      Choose by numbered indices (shown in the enumerated list).
  --first N
      Pick the first N candidates.
  --match REGEX
      Pick candidates whose name OR description matches REGEX (case-insensitive).
  --exact NAME[,NAME2,...]
      Pick packages by exact name(s) from the candidate list (comma- or space-separated).
  (If you provide none of the above, the script prints the list and exits with code 2.)

General:
  --dry-run
      Print planned commands; do not execute.
  --no-aur-questions
      Pass: --answerdiff None --answeredit None --answerclean All
  --yay-opts "<extra yay options>"
      Extra flags passed to yay install (e.g., "--needed --noprovides").

Notes:
  • Pacman --noconfirm does NOT accept removals; this tool removes blockers explicitly when requested.
  • Unknown flags (not recognized by this wrapper) are forwarded to yay in install step (e.g., --needed).

Examples:
  # 1) Search mode: like `yay smtp --needed`, but deterministic:
  yay-resolver smtp --needed --first 1

  # 2) Search mode with explicit pick by index:
  yay-resolver smtp --needed --pick "1 7"

  # 3) Search mode with regex:
  yay-resolver smtp --needed --match '^(exim|postfix)$'

  # 4) Explicit targets + resolve blocker automatically:
  yay-resolver --resolve-conflict yes -- exim python-standard-smtpd

  # 5) Two requested targets in conflict; prefer postfix:
  yay-resolver --resolve-conflict no --prefer pkg=postfix -- exim postfix
EOF
}

# ---- Defaults ----
MODE="prompt"         # yes|no|prompt
PREFER="installed"    # installed|target|first|pkg=<name>
DRY_RUN=0
ADD_YAY_ANSWERS=0

declare -a EXTRA_YAY_OPTS=()  # via --yay-opts
declare -a PASS_THRU_YAY_OPTS=()  # unknown flags forwarded to yay (e.g., --needed)

# Selection (search mode)
PICK_INDICES=""
FIRST_N=""
MATCH_REGEX=""
EXACT_NAMES=""

# Collected args
declare -a TARGETS_EXPLICIT=()  # explicit targets (-S/--)
declare -a SEARCH_TERMS=()
EXPLICIT_MODE=0

# ---- CLI parse ----
if [[ $# -eq 0 ]]; then print_help; exit 2; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --resolve-conflict)
      MODE="${2:-}"; [[ "$MODE" =~ ^(yes|no|prompt)$ ]] || { echo "Invalid --resolve-conflict: $MODE" >&2; exit 2; }
      shift 2;;
    --skip-conflicts) MODE="no"; shift ;;
    --prefer)
      PREFER="${2:-}"; shift 2;;
    --dry-run) DRY_RUN=1; shift ;;
    --yay-opts) EXTRA_YAY_OPTS+=($2); shift 2;;
    --no-aur-questions) ADD_YAY_ANSWERS=1; shift ;;
    -S) EXPLICIT_MODE=1; shift; while [[ $# -gt 0 ]]; do TARGETS_EXPLICIT+=("$1"); shift; done; break ;;
    --) EXPLICIT_MODE=1; shift; while [[ $# -gt 0 ]]; do TARGETS_EXPLICIT+=("$1"); shift; done; break ;;
    --pick) PICK_INDICES="${2:-}"; shift 2;;
    --first) FIRST_N="${2:-}"; [[ "$FIRST_N" =~ ^[0-9]+$ ]] || { echo "--first expects integer" >&2; exit 2; }; shift ;;
    --match) MATCH_REGEX="${2:-}"; shift 2;;
    --exact)  EXACT_NAMES="${2:-}"; shift 2;;
    --*)  # unknown option -> pass through to yay (useful for --needed, --asdeps, etc.)
      PASS_THRU_YAY_OPTS+=("$1"); shift ;;
    *)    # positional
      SEARCH_TERMS+=("$1"); shift ;;
  esac
done

# Pre-answers for yay's AUR prompts
YAY_PREANS=()
if (( ADD_YAY_ANSWERS == 1 )); then
  YAY_PREANS=( --answerdiff None --answeredit None --answerclean All )
fi

# Utilities
pkg_installed() { "$PACMAN_BIN" -Qq "$1" &>/dev/null; }
resolve_pkgname() {
  local token="$1" try="$token"
  # Trim trailing -<chunk> until -Si accepts or no '-' left
  while [[ "$try" == *-* ]]; do
    if "$YAY_BIN" -Si -- "$try" &>/dev/null || "$PACMAN_BIN" -Si -- "$try" &>/dev/null; then
      echo "$try"; return 0
    fi
    try="${try%-*}"
  done
  echo "$token"; return 1
}

# ---- Search mode: build FINAL_TARGETS from search → selection ----
declare -a FINAL_TARGETS=()
if (( EXPLICIT_MODE == 1 )); then
  FINAL_TARGETS=( "${TARGETS_EXPLICIT[@]}" )
else
  if (( ${#SEARCH_TERMS[@]} == 0 )); then
    echo "No -S/-- targets and no search terms supplied. See --help." >&2
    exit 2
  fi

  # Run search (quietly parsable)
  SEARCH_RAW="$("$YAY_BIN" -Ss -- "${SEARCH_TERMS[@]}")" || true

  # Parse repo/pkg lines and capture name + description
  # pacman/yay -Ss output pattern (two-line blocks):
  #   repo/pkgname version ...
  #       description
  mapfile -t LINES < <(printf "%s\n" "$SEARCH_RAW")
  declare -a CAND_NAMES=()
  declare -a CAND_DESC=()
  for ((i=0; i<${#LINES[@]}; i++)); do
    if [[ "${LINES[$i]}" =~ ^([[:alnum:]][[:alnum:]._+-]*)/([[:alnum:]@._+-]+)[[:space:]] ]]; then
      name="${BASH_REMATCH[2]}"
      desc=""
      if (( i+1 < ${#LINES[@]} )); then
        # next line often starts with spaces then description
        desc="$(sed -E 's/^[[:space:]]+//' <<<"${LINES[$((i+1))]}")"
      fi
      CAND_NAMES+=("$name")
      CAND_DESC+=("$desc")
    fi
  done

  if (( ${#CAND_NAMES[@]} == 0 )); then
    echo "No candidates found for: ${SEARCH_TERMS[*]}" >&2
    exit 2
  fi

  # Enumerate for user visibility
  echo "Found ${#CAND_NAMES[@]} candidate(s) for: ${SEARCH_TERMS[*]}"
  for ((k=0; k<${#CAND_NAMES[@]}; k++)); do
    idx=$((k+1))
    printf "%2d  %s\n    %s\n" "$idx" "${CAND_NAMES[$k]}" "${CAND_DESC[$k]}"
  done

  # Selection policy
  declare -A PICKED=()
  add_pick_by_index() { local n="$1"; (( n>=1 && n<=${#CAND_NAMES[@]} )) && PICKED["$((n-1))"]=1; }
  add_pick_by_name() {
    local x="$1"
    for ((k=0; k<${#CAND_NAMES[@]}; k++)); do
      [[ "${CAND_NAMES[$k]}" == "$x" ]] && PICKED["$k"]=1
    done
  }

  if [[ -n "$EXACT_NAMES" ]]; then
    # comma or space separated
    IFS=', ' read -r -a EXN <<<"$EXACT_NAMES"
    for nm in "${EXN[@]}"; do [[ -n "$nm" ]] && add_pick_by_name "$nm"; done
  fi
  if [[ -n "$MATCH_REGEX" ]]; then
    shopt -s nocasematch
    for ((k=0; k<${#CAND_NAMES[@]}; k++)); do
      if [[ "${CAND_NAMES[$k]}" =~ $MATCH_REGEX ]] || [[ "${CAND_DESC[$k]}" =~ $MATCH_REGEX ]]; then
        PICKED["$k"]=1
      fi
    done
    shopt -u nocasematch
  fi
  if [[ -n "$FIRST_N" ]]; then
    for ((k=0; k< FIRST_N && k<${#CAND_NAMES[@]}; k++)); do PICKED["$k"]=1; done
  fi
  if [[ -n "$PICK_INDICES" ]]; then
    # Accept space or comma separated
    for token in $PICK_INDICES; do
      token="${token%,}"
      [[ "$token" =~ ^[0-9]+$ ]] && add_pick_by_index "$token"
    done
  fi

  if (( ${#PICKED[@]} == 0 )); then
    echo
    echo "No selection made. Re-run with one of: --pick \"1 3\", --first N, --match REGEX, or --exact NAME."
    exit 2
  fi

  # Build FINAL_TARGETS preserving order
  for ((k=0; k<${#CAND_NAMES[@]}; k++)); do
    if [[ -n "${PICKED[$k]+x}" ]]; then FINAL_TARGETS+=("${CAND_NAMES[$k]}"); fi
  done
fi

# Forward unknown yay options plus --yay-opts
if (( ${#PASS_THRU_YAY_OPTS[@]} )); then
  EXTRA_YAY_OPTS+=("${PASS_THRU_YAY_OPTS[@]}")
fi

# ---- Conflict handling (same engine as before) ----
declare -a QUEUED_REMOVALS=()

probe_conflict() {
  local -a PROBE_CMD=( "$YAY_BIN" -S --noconfirm --downloadonly "${YAY_PREANS[@]}" ${EXTRA_YAY_OPTS[@]+"${EXTRA_YAY_OPTS[@]}"} "${FINAL_TARGETS[@]}" )
  local log rc
  set +e
  log="$("${PROBE_CMD[@]}" 2>&1 >/dev/null)"; rc=$?
  set -e
  PROBE_LOG="$log"; PROBE_RC="$rc"
}

parse_first_conflict() {
  local log="$1"
  CONFLICT_A=""; CONFLICT_B=""; REMOVE_HINT=""
  local line
  line="$(grep -m1 -E '^:: .* are in conflict' <<<"$log" || true)"
  [[ -n "$line" ]] || return 1
  local raw_a raw_b
  raw_a="$(sed -E 's/^:: ([^ ]+) and .*/\1/' <<<"$line")"
  raw_b="$(sed -E 's/^:: [^ ]+ and ([^ ]+).*/\1/' <<<"$line")"
  CONFLICT_A="$(resolve_pkgname "$raw_a")"
  CONFLICT_B="$(resolve_pkgname "$raw_b")"
  REMOVE_HINT="$(grep -m1 -E '^:: .* Remove ' <<<"$log" | sed -E 's/.* Remove ([^?]+)\?.*/\1/' || true)"
  return 0
}

handle_conflict() {
  local a="$CONFLICT_A" b="$CONFLICT_B" r="$REMOVE_HINT"
  local a_in_targets=0 b_in_targets=0
  for t in "${FINAL_TARGETS[@]}"; do
    [[ "$t" == "$a" ]] && a_in_targets=1
    [[ "$t" == "$b" ]] && b_in_targets=1
  done

  if [[ -n "$r" ]]; then
    if [[ "$MODE" == "prompt" ]]; then
      printf 'Conflict: %s ↔ %s  (remove installed: %s)? [y/N] ' "$a" "$b" "$r" >&2
      read -r ans; [[ "$ans" =~ ^[Yy]$ ]] || MODE="no"
    fi
    if [[ "$MODE" == "yes" ]]; then
      QUEUED_REMOVALS+=("$r"); return 0
    else
      local skip=""
      if (( a_in_targets==1 )) && [[ "$a" != "$r" ]]; then skip="$a"; fi
      if (( b_in_targets==1 )) && [[ "$b" != "$r" ]]; then skip="$b"; fi
      [[ -n "$skip" ]] && FINAL_TARGETS=( "${FINAL_TARGETS[@]/$skip}" ) && echo "Skipping '$skip' due to conflict with installed '$r'." >&2
      return 0
    fi
  else
    local keep="" drop=""
    case "$PREFER" in
      installed)
        if pkg_installed "$a" && ! pkg_installed "$b"; then keep="$a"; drop="$b"; fi
        if pkg_installed "$b" && ! pkg_installed "$a"; then keep="$b"; drop="$a"; fi
        ;;
      target)
        if (( a_in_targets==1 && b_in_targets==0 )); then keep="$a"; drop="$b"; fi
        if (( b_in_targets==1 && a_in_targets==0 )); then keep="$b"; drop="$a"; fi
        ;;
    esac
    if [[ -z "$keep" ]]; then
      if [[ "$PREFER" =~ ^pkg=(.+)$ ]]; then
        local p="${BASH_REMATCH[1]}"
        if [[ "$a" == "$p" || "$b" == "$p" ]]; then keep="$p"; drop=$([[ "$p" == "$a" ]] && echo "$b" || echo "$a")
        fi
      fi
    fi
    if [[ -z "$keep" ]]; then
      for t in "${FINAL_TARGETS[@]}"; do
        if [[ "$t" == "$a" ]]; then keep="$a"; drop="$b"; break; fi
        if [[ "$t" == "$b" ]]; then keep="$b"; drop="$a"; break; fi
      done
      [[ -z "$keep" ]] && return 0
    fi
    FINAL_TARGETS=( "${FINAL_TARGETS[@]/$drop}" )
    echo "Targets '$a' and '$b' conflict. Keeping '$keep' (policy: $PREFER), skipping '$drop'." >&2
    return 0
  fi
}

ITER=0
while :; do
  (( ITER++ )); (( ITER<=12 )) || { echo "Too many conflict-resolution iterations; aborting." >&2; exit 1; }
  probe_conflict
  if [[ "$PROBE_RC" == "0" ]]; then break; fi
  if ! parse_first_conflict "$PROBE_LOG"; then
    echo "Install failed, but no recognizable conflict was found." >&2
    echo "$PROBE_LOG" >&2
    exit 1
  fi
  handle_conflict
done

# ---- Execute plan ----
declare -a CMD_SEQ=()
for r in "${QUEUED_REMOVALS[@]}"; do
  CMD_SEQ+=( "sudo $PACMAN_BIN -Rns --noconfirm -- \"$r\"" )
done
if (( ${#FINAL_TARGETS[@]} > 0 )); then
  CMD_SEQ+=( "$YAY_BIN -S --noconfirm ${YAY_PREANS[*]} ${EXTRA_YAY_OPTS[*]} ${FINAL_TARGETS[*]}" )
fi

if (( DRY_RUN == 1 )); then
  printf 'Planned actions:\n'
  for c in "${CMD_SEQ[@]}"; do printf '  %s\n' "$c"; done
  exit 0
fi

for c in "${CMD_SEQ[@]}"; do
  echo "+ $c"
  eval "$c"
done

echo "Done."

