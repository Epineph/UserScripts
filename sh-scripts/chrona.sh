#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# chrona — one-shot timer/alarm with Wayland notification and optional actions
# ──────────────────────────────────────────────────────────────────────────────
# Features
#   • Timer: run for a duration (e.g., 25m, 1h30m, 00:45:00).
#   • Alarm: ring at a specific time (e.g., 07:30, 2025-11-10 07:30, "tomorrow 08:00").
#   • Live countdown in terminal (default) or detach into background (--detach).
#   • On completion: desktop notification (+ log) and optional maintenance chain:
#       sudo refresh-mirrors; yay -Syyy; yay -Syyu --noconfirm;
#       sudo mkinitcpio -P; sudo grub-mkconfig -o /boot/grub/grub.cfg
#     Then optionally reboot or shutdown.
#   • Safe(ish) handling of sudo when detached: cache credentials or skip actions.
#
# Notes
#   • Requires: bash, coreutils 'date', 'notify-send', yay (if using upgrades).
#   • Detach + sudo: either have a NOPASSWD policy or pre-cache with `sudo -v`.
#   • Lines target width ~81 columns; two-space indentation; 'function' keyword.
# ──────────────────────────────────────────────────────────────────────────────

set -Eeuo pipefail

PROG="chrona"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/chrona"
LOG_FILE="$STATE_DIR/history.log"
DEFAULT_PAGER="${HELP_PAGER:-less -R}"
NOTIFY_BIN="${NOTIFY_BIN:-notify-send}" # override if you prefer something else
SLEEP_STEP=1                            # seconds per countdown step

# ──────────────────────────────────────────────────────────────────────────────
# UI / Help
# ──────────────────────────────────────────────────────────────────────────────

function have() { command -v "$1" >/dev/null 2>&1; }

function page() {
  # Portable pager with fallback to cat
  if [[ -t 1 ]] && have "${DEFAULT_PAGER%% *}"; then
    eval "$DEFAULT_PAGER"
  else
    cat
  fi
}

function show_help() {
  cat <<'HLP' | page
chrona — timer/alarm with optional maintenance actions

USAGE
  chrona (--timer DURATION | --alarm WHEN)
         [--message TEXT] [--title TEXT]
         [--detach] [--quiet]
         [--action ACTION] [--sudo-cache]
         [--dry-run] [--logdir DIR]

MODES
  --timer DURATION
      Relative duration. Accepted formats:
        • "90m", "1h30m10s", "2d3h", "45s"
        • "HH:MM" or "HH:MM:SS" (treated as duration)
        • integer seconds (e.g., "300")
  --alarm WHEN
      Absolute time. Examples (GNU date syntax allowed):
        • "07:30" (today if in future, else tomorrow)
        • "2025-11-10 07:30"
        • "tomorrow 08:00", "next Mon 09:00"

OPTIONS
  --message TEXT    Custom note to show on completion.
  --title TEXT      Notification title (default: "Timer done" or "Alarm done").
  --detach          Run silently in background; only final notification shown.
  --quiet           Suppress countdown even in foreground; show a one-line ETA.
  --sudo-cache      Validate sudo at start (prompts now, avoids blocking later).
  --action ACTION   What to do on completion (default: none). Allowed values:
      none                   → do nothing extra
      upgrade                → run maintenance chain
      reboot                 → reboot
      shutdown               → poweroff
      upgrade+reboot         → maintenance, then reboot
      upgrade+shutdown       → maintenance, then poweroff
  --dry-run         Show parsed plan and exit (no wait, no actions).
  --logdir DIR      Override log directory (default: $XDG_STATE_HOME/chrona).

BEHAVIOR
  • In foreground: prints a live countdown unless --quiet.
  • With --detach: forks into background; ensure sudo is cached or NOPASSWD if
    you select an action requiring privilege. If non-interactive sudo fails,
    the script skips privileged steps but still notifies completion.
  • Notifications use 'notify-send' (Wayland-ready with mako/swaync).

EXAMPLES
  # 25-minute Pomodoro with a note, live countdown
  chrona --timer 25m --message "Break + stretch"

  # Alarm for 07:30 tomorrow, detached; then upgrade and reboot
  chrona --alarm "07:30" --detach --action upgrade+reboot --sudo-cache

  # 1h30m timer, quiet foreground, only notify at the end
  chrona --timer 1h30m --quiet --message "Doctor appointment"

DANGER
  The --action upgrade* variants will modify your system without further
  prompts (uses: refresh-mirrors; yay -Syyy; yay -Syyu --noconfirm; mkinitcpio;
  grub-mkconfig). Use only if you understand the implications.

HLP
}

# ──────────────────────────────────────────────────────────────────────────────
# Logging & notifications
# ──────────────────────────────────────────────────────────────────────────────

function ensure_state() {
  mkdir -p "$STATE_DIR"
  : >/dev/null
}
function logln() {
  ensure_state
  printf '%s %s\n' "$(date -Is)" "$*" \
    >>"$LOG_FILE"
}
function notify() {
  local title="$1" body="$2" urgency="${3:-normal}"
  if have "$NOTIFY_BIN"; then
    "$NOTIFY_BIN" --app-name="$PROG" --urgency="$urgency" "$title" "$body" || true
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Time parsing and formatting
# ──────────────────────────────────────────────────────────────────────────────

function is_hhmm_or_hhmmss() {
  [[ "$1" =~ ^([0-9]{1,2}):([0-9]{2})(:([0-9]{2}))?$ ]]
}

function parse_duration_to_seconds() {
  # Accept sequences of <int><unit> (d/h/m/s), or HH:MM[:SS], or integer seconds
  local in="$1" total=0
  if [[ "$in" =~ ^[0-9]+$ ]]; then
    echo "$in"
    return 0
  fi
  if is_hhmm_or_hhmmss "$in"; then
    local h="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" s="${BASH_REMATCH[4]:-0}"
    echo $((10#$h * 3600 + 10#$m * 60 + 10#$s))
    return 0
  fi
  local rest="$in"
  local matched=0
  while [[ "$rest" =~ ^([0-9]+)([smhd])(.*)$ ]]; do
    local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}"
    rest="${BASH_REMATCH[3]}"
    case "$u" in
    s) total=$((total + 10#$n)) ;;
    m) total=$((total + 10#$n * 60)) ;;
    h) total=$((total + 10#$n * 3600)) ;;
    d) total=$((total + 10#$n * 86400)) ;;
    esac
    matched=1
  done
  if [[ $matched -eq 1 && -z "$rest" ]]; then
    echo "$total"
    return 0
  fi
  # Last resort: try "date -d now + duration" style
  if epoch=$(date -d "now + $in" +%s 2>/dev/null); then
    echo $((epoch - $(date +%s)))
    return 0
  fi
  printf 'Error: could not parse duration "%s"\n' "$in" >&2
  return 1
}

function alarm_to_epoch() {
  # WHEN may be HH:MM[:SS] or any 'date -d' string. HH:MM means today or next day.
  local when="$1" now epoch
  now=$(date +%s)
  if is_hhmm_or_hhmmss "$when"; then
    local today
    today=$(date +%F)
    epoch=$(date -d "$today $when" +%s)
    if ((epoch <= now)); then
      epoch=$(date -d "tomorrow $when" +%s)
    fi
    echo "$epoch"
    return 0
  fi
  epoch=$(date -d "$when" +%s 2>/dev/null) || {
    printf 'Error: could not parse alarm time "%s"\n' "$when" >&2
    return 1
  }
  echo "$epoch"
}

function fmt_hms() {
  local s=$1 h m
  ((h = s / 3600, s %= 3600, m = s / 60, s %= 60))
  printf '%02d:%02d:%02d' "$h" "$m" "$s"
}

# ──────────────────────────────────────────────────────────────────────────────
# Actions on completion
# ──────────────────────────────────────────────────────────────────────────────

function run_upgrade_chain() {
  # As requested by the user; triple -y kept as-is.
  set +e
  logln "ACTION upgrade: sudo refresh-mirrors"
  sudo refresh-mirrors || logln "WARN: refresh-mirrors failed"

  logln "ACTION upgrade: yay -Syyy"
  yay -Syyy || logln "WARN: yay -Syyy failed"

  logln "ACTION upgrade: yay -Syyu --noconfirm"
  yay -Syyu --noconfirm || logln "WARN: yay -Syyu failed"

  logln "ACTION upgrade: sudo mkinitcpio -P"
  sudo mkinitcpio -P || logln "WARN: mkinitcpio failed"

  logln "ACTION upgrade: sudo grub-mkconfig -o /boot/grub/grub.cfg"
  sudo grub-mkconfig -o /boot/grub/grub.cfg || logln "WARN: grub-mkconfig failed"
  set -e
}

function maybe_power() {
  case "${1:-none}" in
  reboot)
    logln "ACTION power: reboot"
    sudo systemctl reboot || sudo reboot
    ;;
  shutdown)
    logln "ACTION power: shutdown"
    sudo systemctl poweroff ||
      sudo shutdown -h now
    ;;
  *) : ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Core waiting loop
# ──────────────────────────────────────────────────────────────────────────────

function countdown_until() {
  local until_epoch="$1" quiet="${2:-0}"
  local now rem last=''
  trap 'printf "\n"; exit 130' INT
  while true; do
    now=$(date +%s)
    if ((now >= until_epoch)); then
      [[ $quiet -eq 0 ]] && printf '\r%s\n' "$(printf '00:00:00   ')"
      break
    fi
    ((rem = until_epoch - now))
    if [[ $quiet -eq 0 ]]; then
      local line
      line="$(fmt_hms "$rem")"
      # Pad to erase residue; carriage return without newline.
      printf '\r%s   ' "$line"
    fi
    sleep "$SLEEP_STEP"
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────────────────────────────────────

MODE="" DUR="" WHEN="" MSG="" TITLE=""
DETACH=0 QUIET=0 DRYRUN=0 SUDOCACHE=0 ACTION="none" POWER="none"
LOGDIR_SET=""

function parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --timer)
      MODE="timer"
      DUR="$2"
      shift 2
      ;;
    --alarm)
      MODE="alarm"
      WHEN="$2"
      shift 2
      ;;
    --message)
      MSG="$2"
      shift 2
      ;;
    --title)
      TITLE="$2"
      shift 2
      ;;
    --detach)
      DETACH=1
      shift
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    --sudo-cache)
      SUDOCACHE=1
      shift
      ;;
    --dry-run)
      DRYRUN=1
      shift
      ;;
    --action)
      case "$2" in
      none | upgrade | reboot | shutdown | upgrade+reboot | upgrade+shutdown)
        ACTION="$2"
        shift 2
        ;;
      *)
        printf 'Error: invalid --action "%s"\n' "$2" >&2
        exit 2
        ;;
      esac
      ;;
    --logdir)
      LOGDIR_SET="$2"
      shift 2
      ;;
    --help | -h)
      show_help
      exit 0
      ;;
    --until) # internal
      UNTIL_EPOCH="$2"
      shift 2
      ;;
    --internal-detached)
      INTERNAL_DETACHED=1
      shift
      ;;
    *)
      printf 'Error: unknown argument "%s"\n' "$1" >&2
      exit 2
      ;;
    esac
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

function main() {
  parse_args "$@"

  if [[ -n "$LOGDIR_SET" ]]; then
    STATE_DIR="$LOGDIR_SET"
    LOG_FILE="$STATE_DIR/history.log"
  fi
  ensure_state

  local until_epoch now readable_end mode_desc
  if [[ -n "${UNTIL_EPOCH:-}" ]]; then
    until_epoch="$UNTIL_EPOCH"
  else
    case "$MODE" in
    timer)
      [[ -n "$DUR" ]] || {
        printf 'Error: --timer needs a duration\n' >&2
        exit 2
      }
      local secs
      secs=$(parse_duration_to_seconds "$DUR")
      until_epoch=$(($(date +%s) + secs))
      mode_desc="TIMER ($DUR)"
      TITLE="${TITLE:-Timer done}"
      ;;
    alarm)
      [[ -n "$WHEN" ]] || {
        printf 'Error: --alarm needs a time\n' >&2
        exit 2
      }
      until_epoch=$(alarm_to_epoch "$WHEN")
      mode_desc="ALARM ($WHEN)"
      TITLE="${TITLE:-Alarm done}"
      ;;
    *)
      printf 'Error: choose one of --timer or --alarm\n' >&2
      exit 2
      ;;
    esac
  fi

  readable_end="$(date -d "@$until_epoch" '+%F %T %Z')"
  local summary="$mode_desc → ends at $readable_end"
  [[ -n "$MSG" ]] && summary="$summary — $MSG"

  if ((DRYRUN)); then
    echo "$PROG plan:"
    echo "  $summary"
    echo "  action: $ACTION"
    echo "  detach: $DETACH, quiet: $QUIET"
    echo "  log:    $LOG_FILE"
    exit 0
  fi

  # Optional sudo caching if actions might need it
  if ((SUDOCACHE)) && [[ "$ACTION" =~ upgrade|reboot|shutdown ]]; then
    sudo -v || true
  fi

  logln "START  $summary"
  if ((DETACH)) && [[ -z "${INTERNAL_DETACHED:-}" ]]; then
    # Re-exec in the background with an internal flag
    if [[ "$ACTION" =~ upgrade|reboot|shutdown ]]; then
      if ! sudo -n true 2>/dev/null; then
        logln "INFO detach without non-interactive sudo; privileged steps may be skipped"
      fi
    fi
    setsid -f -- "$0" --internal-detached --until "$until_epoch" \
      "${MODE:+--$MODE}" "${DUR:+$DUR}" "${WHEN:+$WHEN}" \
      "${MSG:+--message "$MSG"}" "${TITLE:+--title "$TITLE"}" \
      "${QUIET:+--quiet}" "${ACTION:+--action "$ACTION"}" \
      "${LOGDIR_SET:+--logdir "$LOGDIR_SET"}" \
      >/dev/null 2>&1 || true
    echo "$PROG: detached → $summary"
    exit 0
  fi

  # Foreground or internal detached path
  if ((QUIET)) || ((${INTERNAL_DETACHED:-0})); then
    echo "$PROG: $summary"
  fi
  countdown_until "$until_epoch" "$QUIET"

  # Completion
  logln "DONE   $summary"
  notify "$TITLE" "${MSG:-$mode_desc complete}" "normal"

  # Actions
  case "$ACTION" in
  none) : ;;
  upgrade | upgrade+reboot | upgrade+shutdown)
    if sudo -n true 2>/dev/null; then
      run_upgrade_chain
    else
      # Attempt interactive sudo if in foreground; skip if detached
      if ((${INTERNAL_DETACHED:-0})); then
        logln "SKIP: privileged upgrade (no sudo cache in detached mode)"
      else
        echo "[chrona] privileged steps require sudo; continuing…"
        run_upgrade_chain || true
      fi
    fi
    case "$ACTION" in
    upgrade+reboot) maybe_power reboot ;;
    upgrade+shutdown) maybe_power shutdown ;;
    esac
    ;;
  reboot) maybe_power reboot ;;
  shutdown) maybe_power shutdown ;;
  esac

  exit 0
}

main "$@"
