#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# augment-install-from-log.sh — add missing optdeps to your install command
# ──────────────────────────────────────────────────────────────────────────────
# Purpose
#   Parse a pacman/yay install log that contains "Optional dependencies for …"
#   sections and add all *pending* (and unspecified) optdeps that:
#     • are not already listed in your install command, and
#     • actually exist as packages (repo or AUR).
#
# Outputs
#   • Augmented install command (stdout, one-liner by default).
#   • <outdir>/added-packages.txt          — packages to add (one per line).
#   • <outdir>/unavailable-packages.txt    — names seen but not resolvable.
#
# Notes
#   • Excludes any optdep marked “[installed]”.
#   • Accepts either a source install file line (e.g. your install-3.sh) or an
#     explicit baseline list file. It is robust to “gen_log” and extra words.
#   • Verifies existence via `yay -Si` (or `paru -Si` / `pacman -Si`).
#   • You can choose helper via --helper (yay|paru|pacman) and flags for -S.
#
# Style
#   • Bash with 2-space indents; 81-column conscious; explicit `function` style.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Defaults
# ──────────────────────────────────────────────────────────────────────────────
HELPER="yay"           # yay|paru|pacman
SFLAGS="-S --needed"   # flags passed before package list
INSTALL_FILE=""        # file containing your base command (e.g. install-3.sh)
BASELINE_LIST=""       # alternative: file with plain package names
LOG_FILE=""            # pacman/yay verbose log you pasted (r-installs.log)
OUTDIR="./augment-out" # where to write lists
ONELINE=1              # 1: one-liner output; 0: multi-line with backslashes
QUIET=0                # 1: suppress info logs

# ──────────────────────────────────────────────────────────────────────────────
# Help
# ──────────────────────────────────────────────────────────────────────────────
function show_help() {
  "${HELP_PAGER:-cat}" <<'HLP'
augment-install-from-log.sh — add missing optdeps to your install command

USAGE
  augment-install-from-log.sh -l r-installs.log -i install-3.sh [options]
  augment-install-from-log.sh -l r-installs.log -b baseline.txt [options]

ARGUMENTS
  -l, --log FILE          Log file containing "Optional dependencies for …" sections.
  -i, --install FILE      File that contains your base install command line
                          (first line with 'yay|paru|pacman ... -S ...' is used).
  -b, --baseline FILE     Alternative to --install: plain list of baseline packages
                          (whitespace/newline separated).
  -o, --outdir DIR        Output directory for the two result lists (default: ./augment-out).
  -H, --helper NAME       Package helper: yay | paru | pacman (default: yay).
  -F, --flags "STR"       Flags to pass before packages (default: -S --needed).
      --multiline         Emit multi-line augmented command with trailing backslashes.
  -q, --quiet             Reduce chatter.

BEHAVIOR
  • Adds only optional deps that are pending (or unspecified) in the log and
    not already in your baseline.
  • Verifies package existence via HELPER -Si NAME (falls through to pacman -Si).
  • Writes:
       <outdir>/added-packages.txt
       <outdir>/unavailable-packages.txt
  • Prints the augmented command to stdout.

EXAMPLES
  1) Use your script as baseline:
     augment-install-from-log.sh -l ~/Documents/r-installs.log \
       -i ~/Documents/install-3.sh -o ~/Documents/aug-out

  2) If you have a plain list:
     augment-install-from-log.sh -l r-installs.log -b baseline.txt --multiline

EXIT CODES
  0 on success; non-zero on errors.

HLP
}

# ──────────────────────────────────────────────────────────────────────────────
# Logging helpers
# ──────────────────────────────────────────────────────────────────────────────
function log() { ((QUIET)) || printf '[-] %s\n' "$*" >&2; }
function die() {
  printf '[X] %s\n' "$*" >&2
  exit 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Argparse
# ──────────────────────────────────────────────────────────────────────────────
function parse_args() {
  while (($#)); do
    case "$1" in
    -l | --log)
      LOG_FILE=${2-}
      shift 2
      ;;
    -i | --install)
      INSTALL_FILE=${2-}
      shift 2
      ;;
    -b | --baseline)
      BASELINE_LIST=${2-}
      shift 2
      ;;
    -o | --outdir)
      OUTDIR=${2-}
      shift 2
      ;;
    -H | --helper)
      HELPER=${2-}
      shift 2
      ;;
    -F | --flags)
      SFLAGS=${2-}
      shift 2
      ;;
    --multiline)
      ONELINE=0
      shift
      ;;
    -q | --quiet)
      QUIET=1
      shift
      ;;
    -h | --help)
      show_help
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
    esac
  done

  [[ -n "$LOG_FILE" ]] || die "Missing --log FILE"
  [[ -f "$LOG_FILE" ]] || die "Log not found: $LOG_FILE"

  if [[ -n "$INSTALL_FILE" && -n "$BASELINE_LIST" ]]; then
    die "Use only one of --install or --baseline"
  fi
  if [[ -z "$INSTALL_FILE" && -z "$BASELINE_LIST" ]]; then
    die "Provide --install or --baseline"
  fi

  case "$HELPER" in
  yay | paru | pacman) : ;;
  *) die "--helper must be yay|paru|pacman" ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Baseline extraction
#   • From install file: find first line with (yay|paru|pacman).* -S and take
#     tokens after -S flags, skipping any that start with '-'.
#   • From baseline list: read tokens directly.
# ──────────────────────────────────────────────────────────────────────────────
function extract_baseline() {
  declare -gA BASE=()
  if [[ -n "$INSTALL_FILE" ]]; then
    [[ -f "$INSTALL_FILE" ]] || die "Install file not found: $INSTALL_FILE"
    local line
    # Greedy capture: first matching line with helper and -S
    line=$(grep -E -m1 '(^|[[:space:]])(yay|paru|pacman)[[:space:]].*-S([[:space:]]|$)' \
      "$INSTALL_FILE" || true)
    [[ -n "$line" ]] || die "No '-S' command line found in $INSTALL_FILE"

    # Strip everything up to the first ' -S ' occurrence (inclusive).
    # Then split remaining tokens, drop option-like tokens.
    line="${line#*-S}"
    # shellcheck disable=SC2206
    local toks=("$line")
    for t in "${toks[@]}"; do
      [[ "$t" == -* ]] && continue
      [[ "$t" == ";" ]] && continue
      [[ "$t" =~ ^[A-Za-z0-9@._+-]+$ ]] || continue
      BASE["$t"]=1
    done
  else
    # From baseline list file
    while read -r t; do
      for w in "${t[@]}"; do
        [[ "$w" =~ ^[A-Za-z0-9@._+-]+$ ]] || continue
        BASE["$w"]=1
      done
    done <"$BASELINE_LIST"
  fi
  ((${#BASE[@]})) || die "Baseline package set is empty"
  log "Baseline packages: ${#BASE[@]}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Parse optional dependencies from log
#   • Collect names under "Optional dependencies for X".
#   • Skip lines containing "[installed]".
#   • Extract leftmost token (strip trailing ':').
# ──────────────────────────────────────────────────────────────────────────────
function parse_optdeps_from_log() {
  declare -gA OPTDEPS_RAW=()
  awk '
    BEGIN{inblock=0}
    /^Optional dependencies for /{inblock=1; next}
    {
      if(inblock==1){
        if($0 ~ /^[[:space:]]+[[:graph:]]/){
          line=$0
          gsub(/^[[:space:]]+/, "", line)
          # drop comment after colon
          split(line, A, ":")
          name=A[1]
          # drop trailing status like [pending] / [installed]
          sub(/[[:space:]]+\[.*\]$/, "", name)
          if(index(line,"[installed]")==0){
            print name
          }
          next
        } else {
          inblock=0
        }
      }
    }
  ' "$LOG_FILE" | while read -r n; do
    # sanitize
    n=${n%% *}
    n=${n%%	*}
    n=${n//[$'\r']/}
    [[ -n "$n" ]] || continue
    OPTDEPS_RAW["$n"]=1
  done
  log "Optdep names seen (raw): ${#OPTDEPS_RAW[@]}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Package existence check
#   • Return 0 if resolvable by HELPER -Si or pacman -Si.
# ──────────────────────────────────────────────────────────────────────────────
function pkg_exists() {
  local pkg=$1
  case "$HELPER" in
  yay | paru)
    "$HELPER" -Si -- "$pkg" &>/dev/null && return 0
    ;;
  pacman)
    pacman -Si -- "$pkg" &>/dev/null && return 0
    ;;
  esac
  # fallback to pacman in case helper missing
  pacman -Si -- "$pkg" &>/dev/null && return 0 || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Build additions: not in BASE, resolvable via *-Si
# ──────────────────────────────────────────────────────────────────────────────
function compute_additions() {
  mkdir -p "$OUTDIR"
  : >"$OUTDIR/added-packages.txt"
  : >"$OUTDIR/unavailable-packages.txt"

  declare -a add=() miss=()
  for name in "${!OPTDEPS_RAW[@]}"; do
    # skip if already present
    [[ -n "${BASE[$name]:-}" ]] && continue
    # Verify existence
    if pkg_exists "$name"; then
      add+=("$name")
    else
      miss+=("$name")
    fi
  done

  # sort unique, stable
  printf '%s\n' "${add[@]:-}" | LC_ALL=C sort -u >"$OUTDIR/added-packages.txt"
  printf '%s\n' "${miss[@]:-}" | LC_ALL=C sort -u >"$OUTDIR/unavailable-packages.txt"

  local na nb
  na=$(wc -l <"$OUTDIR/added-packages.txt" || echo 0)
  nb=$(wc -l <"$OUTDIR/unavailable-packages.txt" || echo 0)
  log "Addable packages: ${na}"
  log "Unresolvable names: ${nb}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Emit augmented command to stdout
# ──────────────────────────────────────────────────────────────────────────────
function emit_augmented_command() {
  # Compose baseline ∪ additions (preserve baseline order best-effort)
  declare -a baseline ordered extras
  # reconstruct baseline in the order we parsed
  for k in "${!BASE[@]}"; do baseline+=("$k"); done
  # We do not have original order; sort to be reproducible
  baseline=("$(printf '%s\n' "${baseline[@]}" | LC_ALL=C sort -u)")

  mapfile -t extras <"$OUTDIR/added-packages.txt"

  if ((ONELINE)); then
    printf '%s %s %s\n' "$HELPER" "$SFLAGS" \
      "$(printf '%s ' "${baseline[@]}" "${extras[@]}")"
  else
    # multi-line, trailing backslashes, 81-column aware (simple greedy wrap)
    printf '%s %s \\\n' "$HELPER" "$SFLAGS"
    local line="" first=1
    for p in "${baseline[@]}" "${extras[@]}"; do
      local next="$p"
      if ((${#line} + 1 + ${#next} > 78)); then
        printf '  %s \\\n' "$line"
        line="$next"
      else
        if [[ -z "$line" ]]; then line="$next"; else line="$line $next"; fi
      fi
      first=0
    done
    [[ -n "$line" ]] && printf '  %s\n' "$line"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
function main() {
  parse_args "$@"
  extract_baseline
  parse_optdeps_from_log
  compute_additions
  emit_augmented_command
  log "Wrote: $OUTDIR/added-packages.txt"
  log "Wrote: $OUTDIR/unavailable-packages.txt"
}

# ──────────────────────────────────────────────────────────────────────────────
# Entry
# ──────────────────────────────────────────────────────────────────────────────
if [[ "${1-}" == "--help" || "${1-}" == "-h" ]]; then
  show_help
  exit 0
fi
main "$@"
