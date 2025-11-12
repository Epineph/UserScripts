#!/usr/bin/env bash
# schedule_power — Countdown to reboot/poweroff with notifications, idle handling, and Hyprland cancel keybind.
#
# Features
#   • Live HH:MM:SS countdown to reboot (-r) or shutdown (-s).
#   • Notifications at 30m, 10m, 3m, 1m, 15s (unless silenced); final 10s warning is always shown.
#   • Hyprland-friendly cancel: script listens for SIGUSR1. Use `schedule_power --cancel` (bind a key).
#   • Idle-aware: runs under systemd-inhibit by default; if the timer expires while idle, adds +5 minutes once.
#   • Single-instance with PID file in /run/user/$UID; `--force` replaces an active schedule.
#
# Usage
#   schedule_power -r|-s [-H hours] [-M minutes] [-S seconds]
#                  [--silence|--silence-warnings|--silence=alarm|--silence=output|--silence=all|--quiet]
#                  [--no-inhibit] [--force] [--cancel] [--cancel-hint "SUPER+SHIFT+X"]
#
# Examples
#   schedule_power -r -M 20
#   schedule_power -s -H 1 -M 15 --silence         # quiet popups (still shows final 10s)
#   schedule_power -s -M 5  --quiet                # no terminal spam, no intermediate popups; final 10s still shown
#   schedule_power --cancel                        # cancels currently scheduled action (via SIGUSR1)
#
# Exit codes
#   0 ok/cancelled, 1 usage, 2 dependency, 3 runtime
#
# Author: You
# License: MIT

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.3.0"

# ────────────── Defaults ──────────────
HOURS=0
MINUTES=0
SECONDS=0
MODE=""
QUIET=false
SILENCE_WARN=false     # suppress intermediate notifications
SILENCE_OUTPUT=false   # suppress terminal countdown
ALWAYS_FINAL=true      # 10s final warning always shown
NO_INHIBIT=false
FORCE=false
DO_CANCEL=false
CANCEL_HINT="your Hyprland cancel key"  # shown in last notices
PIDFILE="/run/user/${UID}/schedule_power.pid"
STATEFILE="/run/user/${UID}/schedule_power.state"
INHIBITED_FLAG="${INHIBITED:-0}"

# ────────────── Small helpers ──────────────
die() { echo "schedule_power: $*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

notify() { # intermediate notifications (obey SILENCE_WARN)
  local title="$1"; shift
  local body="$*"
  $SILENCE_WARN && return 0
  if have notify-send; then
    notify-send --app-name="schedule_power" "$title" "$body" || true
  else
    # Fallback to stderr if libnotify is absent (still obey SILENCE_WARN)
    echo "[NOTIFY] $title — $body" >&2
  fi
}

notify_final() { # final 10s warning (never silenced)
  local title="$1"; shift
  local body="$*"
  if have notify-send; then
    notify-send --urgency=critical --app-name="schedule_power" "$title" "$body" || true
  else
    echo "[FINAL WARNING] $title — $body" >&2
  fi
}

say() { # terminal output (obeys SILENCE_OUTPUT or QUIET)
  $QUIET && return 0
  $SILENCE_OUTPUT && return 0
  echo "$@"
}

progress_line() { # one-line countdown
  $QUIET && return 0
  $SILENCE_OUTPUT && return 0
  if [ -t 1 ]; then
    printf "\rTime left: %02d:%02d:%02d" "$1" "$2" "$3"
  fi
}

# ────────────── Long options pre-parse ──────────────
# Supports: --quiet, --silence, --silence-warnings, --silence=alarm|output|all, --silence-all,
#           --no-inhibit, --force, --cancel, --cancel-hint <str>
LONG_ARGS=()
while (( "$#" )); do
  case "$1" in
    --quiet) QUIET=true; shift ;;
    --silence|--silence-warnings) SILENCE_WARN=true; shift ;;
    --silence=alarm) SILENCE_WARN=true; shift ;;
    --silence=output) SILENCE_OUTPUT=true; shift ;;
    --silence=all|--silence-all) QUIET=true; SILENCE_WARN=true; SILENCE_OUTPUT=true; shift ;;
    --no-inhibit) NO_INHIBIT=true; shift ;;
    --force) FORCE=true; shift ;;
    --cancel) DO_CANCEL=true; shift ;;
    --cancel-hint)
      [ $# -ge 2 ] || die "missing argument to --cancel-hint"
      CANCEL_HINT="$2"; shift 2 ;;
    --) shift; break ;;
    -*|*) LONG_ARGS+=("$1"); shift ;;
  esac
done
# Rebuild positional params for getopts
set -- "${LONG_ARGS[@]}" "$@"

# ────────────── Usage ──────────────
usage() {
  cat <<'EOF'
Usage:
  schedule_power -r|-s [-H hours] [-M minutes] [-S seconds]
                 [--silence|--silence-warnings|--silence=alarm|--silence=output|--silence=all|--quiet]
                 [--no-inhibit] [--force] [--cancel] [--cancel-hint "SUPER+SHIFT+X"]

Options:
  -r                 Reboot after the countdown.
  -s                 Shutdown after the countdown.
  -H, -M, -S         Delay components (non-negative integers).
  -h                 Show this help.

  --cancel           Cancel the currently running schedule (sends SIGUSR1).
  --force            Replace/override an existing running schedule.

  --silence, --silence-warnings, --silence=alarm
                     Suppress intermediate notifications (30m/10m/3m/1m/15s).
  --silence=output   Suppress terminal countdown, keep notifications.
  --silence=all, --silence-all, --quiet
                     Suppress terminal countdown and intermediate notifications.
                     The final 10-second warning is ALWAYS shown.

  --no-inhibit       Do not run under systemd-inhibit (default is to inhibit idle/sleep).
  --cancel-hint STR  Text shown in late notifications to remind the cancel key (default placeholder).

Notes:
  • A final 10-second warning is always displayed (requires libnotify for GUI popup).
  • A single instance runs per user. Use --force to start a new one.
  • If the timer expires while the session is idle, the script adds +5 minutes once and alerts on return.
EOF
}

# ────────────── Cancel handling ──────────────
do_cancel() {
  if [ -f "$PIDFILE" ]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      kill -USR1 "$pid" || true
      say "Requested cancellation for PID $pid."
      exit 0
    fi
  fi
  die "no active schedule found."
}

$DO_CANCEL && do_cancel

# ────────────── Parse short options ──────────────
while getopts ":rsH:M:S:h" opt; do
  case "$opt" in
    r) MODE="reboot" ;;
    s) MODE="shutdown" ;;
    H) HOURS="$OPTARG" ;;
    M) MINUTES="$OPTARG" ;;
    S) SECONDS="$OPTARG" ;;
    h) usage; exit 0 ;;
    \?) usage; exit 1 ;;
  esac
done

[[ -n "$MODE" ]] || { usage; exit 1; }
[[ "$HOURS" =~ ^[0-9]+$ && "$MINUTES" =~ ^[0-9]+$ && "$SECONDS" =~ ^[0-9]+$ ]] || die "H/M/S must be non-negative integers."

TOTAL_DELAY=$(( HOURS*3600 + MINUTES*60 + SECONDS ))
(( TOTAL_DELAY > 0 )) || die "total delay must be > 0 seconds."

# ────────────── Ensure runtime dirs ──────────────
mkdir -p "/run/user/${UID}" || true

# ────────────── Single-instance guard ──────────────
if [ -f "$PIDFILE" ]; then
  existing="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "${existing:-}" ] && kill -0 "$existing" 2>/dev/null; then
    if ! $FORCE; then
      die "another schedule is running (PID $existing). Use --force or --cancel."
    else
      say "Replacing existing schedule (PID $existing)."
      kill -USR1 "$existing" 2>/dev/null || true
      sleep 0.2
    fi
  fi
fi
echo $$ > "$PIDFILE"

cleanup() { rm -f "$PIDFILE" "$STATEFILE" 2>/dev/null || true; }
trap cleanup EXIT

# ────────────── Signal trap (cancel) ──────────────
CANCELLED=false
trap 'CANCELLED=true' USR1 INT

# ────────────── Re-exec under systemd-inhibit unless disabled ──────────────
if ! $NO_INHIBIT; then
  if [ "$INHIBITED_FLAG" != "1" ]; then
    if have systemd-inhibit; then
      export INHIBITED=1
      exec systemd-inhibit --what=idle:sleep --why="schedule_power $MODE" --mode=block "$0" "$@" || exit 3
    else
      say "systemd-inhibit not found; proceeding without inhibition."
    fi
  fi
fi

# ────────────── Idle detection via loginctl (best-effort) ──────────────
SESSION_ID="${XDG_SESSION_ID:-$(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$USER" '$3==u{print $1; exit}')}"
IDLE_SUPPORTED=false
if [ -n "${SESSION_ID:-}" ] && have loginctl; then
  IDLE_SUPPORTED=true
fi

idle_hint() {
  $IDLE_SUPPORTED || { echo "unknown"; return; }
  loginctl show-session "$SESSION_ID" -p IdleHint 2>/dev/null | awk -F= '{print $2}'
}

# ────────────── Notify plan ──────────────
say "Scheduled $MODE in ${HOURS}h ${MINUTES}m ${SECONDS}s (total ${TOTAL_DELAY}s)."

# thresholds (seconds remaining)
declare -A fired=([1800]=0 [600]=0 [180]=0 [60]=0 [15]=0)
thresholds=(1800 600 180 60 15)

START=$(date +%s)
END=$(( START + TOTAL_DELAY ))
EXTENDED_ON_IDLE=false

# Main loop
while :; do
  $CANCELLED && { say; say "Cancelled."; notify "Cancelled" "The scheduled $MODE was cancelled."; exit 0; }

  NOW=$(date +%s)
  REMAIN=$(( END - NOW ))
  (( REMAIN < 0 )) && REMAIN=0

  # Threshold notifications
  for t in "${thresholds[@]}"; do
    if (( TOTAL_DELAY >= t )) && (( REMAIN == t )) && (( fired[$t] == 0 )); then
      case "$t" in
        1800) notify "30 minutes remaining" "Action: $MODE";;
        600)  notify "10 minutes remaining" "Action: $MODE";;
        180)  notify "3 minutes remaining"  "Action: $MODE — press ${CANCEL_HINT} to cancel";;
        60)   notify "1 minute remaining"   "Action: $MODE — press ${CANCEL_HINT} to cancel";;
        15)   notify "15 seconds remaining" "Action: $MODE — press ${CANCEL_HINT} to cancel";;
      esac
      fired[$t]=1
    fi
  done

  # Final 10s warning (always)
  if (( REMAIN == 10 )); then
    notify_final "Final warning: 10s" "Executing $MODE in 10 seconds."
  fi

  # Render countdown
  h=$(( REMAIN / 3600 ))
  m=$(( (REMAIN % 3600) / 60 ))
  s=$(( REMAIN % 60 ))
  progress_line "$h" "$m" "$s"

  # Exit condition
  if (( REMAIN == 0 )); then
    # If session is idle and we have not extended yet, add +5 minutes once.
    if $IDLE_SUPPORTED && ! $EXTENDED_ON_IDLE; then
      HINT="$(idle_hint)"
      if [ "$HINT" = "yes" ]; then
        EXTENDED_ON_IDLE=true
        END=$(( $(date +%s) + 300 ))
        say; say "Timer expired during idle; adding +5 minutes."
        notify "Idle detected" "Timer expired during idle. Added +5 minutes before $MODE."
        sleep 1
        continue
      fi
    fi
    break
  fi

  sleep 1
done

# Newline after countdown if we printed
$QUIET || $SILENCE_OUTPUT || { [ -t 1 ] && echo; }

say "Time is up! Executing $MODE now..."
if [ "$MODE" = "reboot" ]; then
  notify "Executing reboot" "Now."
  sudo systemctl reboot
else
  notify "Executing shutdown" "Now."
  sudo systemctl poweroff
fi

exit 0

