#!/usr/bin/env bash
set -euo pipefail

PROG="${0##*/}"

# -----------------------------------------------------------------------------
# log-gen
#
# 1) Log any command's stdout/stderr to a timestamped file.
# 2) Reconstruct a reproducible "log-gen yay --needed -S ..." from a yay log.
#
# Pager:
#   - Paging is OFF by default.
#   - Use --paging to page help via bat if available; otherwise cat.
#   - Override via HELP_PAGER="less -R" (or any pager command).
# -----------------------------------------------------------------------------

function die() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 1
}

function have() {
  command -v "$1" >/dev/null 2>&1
}

function trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

function strip_arch_verrel() {
  # If token looks like: name-pkgver-pkgrel (pkgrel typically digits or digits.digits),
  # return "name". Otherwise return token unchanged.
  local t="$1"
  local last="${t##*-}"

  if [[ "$last" =~ ^[0-9]+([.][0-9]+)*$ ]] && [[ "$t" == *-*-* ]]; then
    local tmp="${t%-*}"
    printf '%s' "${tmp%-*}"
  else
    printf '%s' "$t"
  fi
}

function pager_cat_or_bat() {
  if [[ -n "${HELP_PAGER:-}" ]]; then
    # Split HELP_PAGER on whitespace (common convention, like PAGER).
    # shellcheck disable=SC2206
    local -a cmd=(${HELP_PAGER})
    "${cmd[@]}"
    return
  fi

  if [[ "${PAGING:-0}" -eq 1 ]] && have bat; then
    bat --paging=always --style="grid,header,snip" --italic-text="always" \
      --theme="gruvbox-dark" --squeeze-blank --squeeze-limit="2" \
      --force-colorization --terminal-width="auto" --tabs="2" \
      --chop-long-lines
  else
    cat
  fi
}

function show_help() {
  cat <<EOF | pager_cat_or_bat
Usage:
  $PROG [--dir DIR] [--] <command> [args...]
  $PROG --from-yay-log FILE [--include selected|all|failures] [--run]
  $PROG --check-aur

Core:
  --dir DIR
      Log root directory. Default: \$XDG_STATE_HOME/log-gen or ~/.local/state/log-gen

  --paging
      Page help output via bat if available; otherwise cat.
      You may override with: HELP_PAGER="less -R" (or similar)

AUR / yay:
  --check-aur
      Quick connectivity checks for AUR HTTP, RPC, and git.

  --from-yay-log FILE
      Parse a yay output log and print a reproducible:
        $PROG yay --needed -S <pkgs...>

  --include selected|all|failures
      selected  (default): Sync Explicit + AUR Explicit
      all:                also includes AUR Dependency/Make/Check Dependency
      failures:           only packages that failed fetching (safe minimal retry set)

  --run
      Execute the reconstructed yay command (and log it).

Examples:
  # Log any command:
  $PROG pacman -Syu

  # Check AUR health:
  $PROG --check-aur

  # Rebuild a yay install command from your log and print it:
  $PROG --from-yay-log /path/to/output_103.txt

  # Rebuild, but only retry the failed AUR fetches:
  $PROG --from-yay-log /path/to/output_103.txt --include failures

  # Rebuild and run (logging the run too):
  $PROG --from-yay-log /path/to/output_103.txt --run
EOF
}

function default_log_root() {
  local root="${XDG_STATE_HOME:-$HOME/.local/state}/log-gen"
  printf '%s' "$root"
}

function mk_run_logdir() {
  local root="$1"
  local stamp dir
  stamp="$(date +%Y%m%d-%H%M%S)"
  dir="$root/$stamp"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

function shell_join() {
  local out=()
  local a
  for a in "$@"; do
    out+=("$(printf '%q' "$a")")
  done
  printf '%s ' "${out[@]}"
}

function run_and_log() {
  local log_root="$1"
  shift
  [[ $# -ge 1 ]] || die "No command provided."

  local dir logfile cmdfile ecfile
  dir="$(mk_run_logdir "$log_root")"
  logfile="$dir/output.log"
  cmdfile="$dir/command.sh"
  ecfile="$dir/exit_code.txt"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf '%s\n' "$(shell_join "$@")"
  } >"$cmdfile"
  chmod +x "$cmdfile"

  set +e
  "$@" 2>&1 | tee "$logfile"
  local ec="${PIPESTATUS[0]}"
  set -e

  printf '%s\n' "$ec" >"$ecfile"
  return "$ec"
}

function aur_check() {
  have curl || die "curl not found."
  have git || die "git not found."

  local ok=1

  # Use GET (AUR rejects HEAD with 405).
  if curl -fsS --retry 3 --retry-all-errors -o /dev/null \
    https://aur.archlinux.org/; then
    printf 'AUR HTTP: OK\n'
  else
    printf 'AUR HTTP: FAIL\n'
    ok=0
  fi

  if curl -fsS --retry 3 --retry-all-errors -o /dev/null \
    'https://aur.archlinux.org/rpc/?v=5&type=info&arg[]=yay'; then
    printf 'AUR RPC : OK\n'
  else
    printf 'AUR RPC : FAIL\n'
    ok=0
  fi

  local i
  for i in 1 2 3; do
    if git ls-remote https://aur.archlinux.org/yay.git HEAD >/dev/null 2>&1; then
      printf 'AUR GIT : OK\n'
      break
    fi
    if [[ "$i" -eq 3 ]]; then
      printf 'AUR GIT : FAIL\n'
      ok=0
    fi
    sleep 1
  done

  [[ "$ok" -eq 1 ]]
}

function extract_pkgs_from_yay_log() {
  local file="$1"
  local include_mode="$2"

  [[ -f "$file" ]] || die "Log file not found: $file"

  local -a lines=()
  mapfile -t lines <"$file"

  local -a raw=()
  local line payload

  for line in "${lines[@]}"; do
    case "$line" in
      AUR\ Explicit\ \(*\):*)
        if [[ "$include_mode" == "selected" || "$include_mode" == "all" ]]; then
          payload="${line#*: }"
          raw+=("$payload")
        fi
        ;;
      Sync\ Explicit\ \(*\):*)
        if [[ "$include_mode" == "selected" || "$include_mode" == "all" ]]; then
          payload="${line#*: }"
          raw+=("$payload")
        fi
        ;;
      AUR\ Dependency\ \(*\):*|AUR\ Make\ Dependency\ \(*\):*|AUR\ Check\ Dependency\ \(*\):*)
        if [[ "$include_mode" == "all" ]]; then
          payload="${line#*: }"
          raw+=("$payload")
        fi
        ;;
      Failed\ to\ download\ PKGBUILD:\ *)
        if [[ "$include_mode" == "failures" ]]; then
          raw+=("${line#Failed to download PKGBUILD: }")
        fi
        ;;
      error\ fetching\ *:*)
        if [[ "$include_mode" == "failures" ]]; then
          payload="${line#error fetching }"
          payload="${payload%%:*}"
          raw+=("$payload")
        fi
        ;;
    esac
  done

  # If selected/all found nothing, fall back to failures extraction.
  if [[ "${#raw[@]}" -eq 0 ]] && [[ "$include_mode" != "failures" ]]; then
    for line in "${lines[@]}"; do
      case "$line" in
        Failed\ to\ download\ PKGBUILD:\ *)
          raw+=("${line#Failed to download PKGBUILD: }")
          ;;
        error\ fetching\ *:*)
          payload="${line#error fetching }"
          payload="${payload%%:*}"
          raw+=("$payload")
          ;;
      esac
    done
  fi

  local -a pkgs=()
  declare -A seen=()

  local chunk
  for chunk in "${raw[@]}"; do
    if [[ "$chunk" == *","* ]]; then
      local IFS=,
      local -a parts=()
      read -r -a parts <<<"$chunk"
      local p name
      for p in "${parts[@]}"; do
        name="$(trim "$p")"
        name="$(strip_arch_verrel "$name")"
        [[ -n "$name" ]] || continue
        if [[ -z "${seen[$name]+x}" ]]; then
          seen["$name"]=1
          pkgs+=("$name")
        fi
      done
    else
      local name
      name="$(trim "$chunk")"
      name="$(strip_arch_verrel "$name")"
      [[ -n "$name" ]] || continue
      if [[ -z "${seen[$name]+x}" ]]; then
        seen["$name"]=1
        pkgs+=("$name")
      fi
    fi
  done

  printf '%s\n' "${pkgs[@]}"
}

function print_yay_cmd() {
  local prefix="$1"
  shift
  local -a pkgs=("$@")
  [[ "${#pkgs[@]}" -gt 0 ]] || die "No packages found in log."

  printf '%s \\\n' "$prefix"
  local i
  for ((i=0; i<${#pkgs[@]}; i++)); do
    if (( i == ${#pkgs[@]} - 1 )); then
      printf '  %s\n' "${pkgs[i]}"
    else
      printf '  %s \\\n' "${pkgs[i]}"
    fi
  done
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
PAGING=0
LOG_ROOT="$(default_log_root)"
FROM_YAY_LOG=""
INCLUDE_MODE="selected"
DO_RUN=0
DO_CHECK_AUR=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    --paging)
      PAGING=1
      shift
      ;;
    --dir)
      [[ $# -ge 2 ]] || die "--dir requires a value."
      LOG_ROOT="$2"
      shift 2
      ;;
    --check-aur)
      DO_CHECK_AUR=1
      shift
      ;;
    --from-yay-log)
      [[ $# -ge 2 ]] || die "--from-yay-log requires a file path."
      FROM_YAY_LOG="$2"
      shift 2
      ;;
    --include)
      [[ $# -ge 2 ]] || die "--include requires: selected|all|failures"
      INCLUDE_MODE="$2"
      shift 2
      ;;
    --run)
      DO_RUN=1
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

INCLUDE_MODE="${INCLUDE_MODE,,}"
case "$INCLUDE_MODE" in
  selected|all|failures) ;;
  *) die "Invalid --include: $INCLUDE_MODE (expected selected|all|failures)" ;;
esac

mkdir -p "$LOG_ROOT"

if [[ "$DO_CHECK_AUR" -eq 1 ]]; then
  aur_check
  exit $?
fi

if [[ -n "$FROM_YAY_LOG" ]]; then
  mapfile -t pkgs < <(extract_pkgs_from_yay_log "$FROM_YAY_LOG" "$INCLUDE_MODE")

  print_yay_cmd "$PROG yay --needed -S" "${pkgs[@]}"

  if [[ "$DO_RUN" -eq 1 ]]; then
    run_and_log "$LOG_ROOT" yay --needed -S "${pkgs[@]}"
  fi

  exit 0
fi

# Default: log the provided command.
[[ $# -ge 1 ]] || { show_help; exit 2; }
run_and_log "$LOG_ROOT" "$@"

