#!/usr/bin/env bash
# schedule_power — Countdown to reboot/poweroff with notifications, idle handling, and Hyprland cancel keybind.
set -Eeuo pipefail
IFS=$'\n\t'
VERSION="1.4.1"

# ───────── Refuse root (avoid /run/user/0 confusion) ─────────
if [ "$EUID" -eq 0 ]; then
  echo "schedule_power: do not run as root/sudo. Run as your user." >&2
  exit 1
fi

# ───────── Defaults ─────────
HOURS=0; MINUTES=0; SECONDS=0; MODE=""
QUIET=false; SILENCE_WARN=false; SILENCE_OUTPUT=false
NO_INHIBIT=false; FORCE=false; DO_CANCEL=false
CANCEL_HINT="SUPER+CTRL+X"
PIDFILE="/run/user/${UID}/schedule_power.pid"
STATEFILE="/run/user/${UID}/schedule_power.state"
INHIBITED_FLAG="${INHIBITED:-0}"

die(){ echo "schedule_power: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

usage(){
  if command -v helpout >/dev/null 2>&1; then
    helpout <<'HLP'
# schedule_power — Countdown to reboot/shutdown

**Usage**
  schedule-power -r|-s [-H hours] [-M minutes] [-S seconds] [options]

**Options**
  -r, -s                Reboot or shutdown after the countdown
  -H, -M, -S            Delay components (non-negative integers)
  -h, --help            Show this help and exit
  --cancel              Cancel a running schedule (sends SIGUSR1)
  --force               Replace an existing schedule
  --no-inhibit          Do not wrap under systemd-inhibit
  --cancel-hint STR     Shown in late notifications (default: SUPER+CTRL+X)

**Silencing**
  --silence | --silence-warnings | --silence=alarm
  --silence=output
  --silence=all | --silence-all | --quiet

**Notes**
  Final 10s warning is always shown. Single instance via /run/user/$UID/schedule_power.pid.
HLP
  else
    cat <<'HLP'
schedule_power — Countdown to reboot/shutdown
Usage: schedule-power -r|-s [-H H] [-M M] [-S S] [options]
  -r|-s, -H -M -S, -h/--help, --cancel, --force, --no-inhibit, --cancel-hint STR
Silencing: --silence[=alarm]|--silence=output|--silence-all|--quiet
HLP
  fi
}

notify(){ $SILENCE_WARN && return 0; local t="$1"; shift; local b="$*"; if have notify-send; then notify-send --app-name="schedule_power" "$t" "$b" || true; else echo "[NOTIFY] $t — $b" >&2; fi; }
notify_final(){ local t="$1"; shift; local b="$*"; if have notify-send; then notify-send --urgency=critical --app-name="schedule_power" "$t" "$b" || true; else echo "[FINAL] $t — $b" >&2; fi; }
say(){ $QUIET || $SILENCE_OUTPUT || echo "$*"; }
progress_line(){ $QUIET || $SILENCE_OUTPUT || { [ -t 1 ] && printf "\rTime left: %02d:%02d:%02d" "$1" "$2" "$3"; }; }

# ───────── Long opts first ─────────
LONG_ARGS=()
while (($#)); do
  case "$1" in
    --quiet|--silence-all|--silence=all) QUIET=true; SILENCE_WARN=true; SILENCE_OUTPUT=true; shift;;
    --silence|--silence-warnings|--silence=alarm) SILENCE_WARN=true; shift;;
    --silence=output) SILENCE_OUTPUT=true; shift;;
    --no-inhibit) NO_INHIBIT=true; shift;;
    --force) FORCE=true; shift;;
    --cancel) DO_CANCEL=true; shift;;
    --cancel-hint) [ $# -ge 2 ] || die "missing argument to --cancel-hint"; CANCEL_HINT="$2"; shift 2;;
    --help|-h) usage; exit 0;;
    --) shift; break;;
    -*|*) LONG_ARGS+=("$1"); shift;;
  esac
done
set -- "${LONG_ARGS[@]}" "$@"

# ───────── Cancel path (no inhibit needed) ─────────
if $DO_CANCEL; then
  if [ -f "$PIDFILE" ]; then
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      kill -USR1 "$pid" || true
      echo "Requested cancellation for PID $pid."
      exit 0
    fi
  fi
  die "no active schedule found."
fi

# ───────── Short opts ─────────
while getopts ":rsH:M:S:h" opt; do
  case "$opt" in
    r) MODE="reboot";;
    s) MODE="shutdown";;
    H) HOURS="$OPTARG";;
    M) MINUTES="$OPTARG";;
    S) SECONDS="$OPTARG";;
    h) usage; exit 0;;
    \?) usage; exit 1;;
  esac
done
[[ -n "$MODE" ]] || { usage; exit 1; }
[[ "$HOURS" =~ ^[0-9]+$ && "$MINUTES" =~ ^[0-9]+$ && "$SECONDS" =~ ^[0-9]+$ ]] || die "H/M/S must be non-negative integers."
TOTAL_DELAY=$(( HOURS*3600 + MINUTES*60 + SECONDS ))
(( TOTAL_DELAY > 0 )) || die "total delay must be > 0 seconds."

# ───────── Re-exec under systemd-inhibit BEFORE touching PIDFILE ─────────
if ! $NO_INHIBIT; then
  if [ "$INHIBITED_FLAG" != "1" ]; then
    if have systemd-inhibit; then
      export INHIBITED=1
      exec systemd-inhibit --what=idle:sleep --mode=block --why="schedule_power $MODE" "$0" "$@" || exit 3
    else
      say "systemd-inhibit not found; proceeding without inhibition."
    fi
  fi
fi

# ───────── Now we are the final process: do single-instance guard & write PID ─────────
mkdir -p "/run/user/${UID}" || true

if [ -f "$PIDFILE" ]; then
  existing="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "${existing:-}" ] && kill -0 "$existing" 2>/dev/null; then
    if $FORCE; then
      say "Existing schedule (PID $existing) detected; requesting cancel…"
      kill -USR1 "$existing" 2>/dev/null || true
      for i in {1..50}; do kill -0 "$existing" 2>/dev/null || break; sleep 0.1; done
      if kill -0 "$existing" 2>/dev/null; then
        say "PID $existing still alive; sending TERM…"
        kill "$existing" 2>/dev/null || true
        for i in {1..50}; do kill -0 "$existing" 2>/dev/null || break; sleep 0.1; done
      fi
      if kill -0 "$existing" 2>/dev/null; then
        die "another schedule is running (PID $existing); could not take over."
      fi
      rm -f "$PIDFILE" 2>/dev/null || true
    else
      die "another schedule is running (PID $existing). Use --force or --cancel."
    fi
  else
    rm -f "$PIDFILE" 2>/dev/null || true
  fi
fi

echo $$ > "$PIDFILE"
cleanup(){ rm -f "$PIDFILE" "$STATEFILE" 2>/dev/null || true; }
trap cleanup EXIT

# ───────── Signals ─────────
CANCELLED=false
trap 'CANCELLED=true' USR1 INT

# ───────── Idle detection ─────────
SESSION_ID="${XDG_SESSION_ID:-$(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$USER" '$3==u{print $1; exit}')}"
IDLE_SUPPORTED=false; [ -n "${SESSION_ID:-}" ] && have loginctl && IDLE_SUPPORTED=true
idle_hint(){ $IDLE_SUPPORTED || { echo "unknown"; return; }; loginctl show-session "$SESSION_ID" -p IdleHint 2>/dev/null | awk -F= '{print $2}'; }

# ───────── Run ─────────
say "Scheduled $MODE in ${HOURS}h ${MINUTES}m ${SECONDS}s (total ${TOTAL_DELAY}s)."

declare -A fired=([1800]=0 [600]=0 [180]=0 [60]=0 [15]=0)
thresholds=(1800 600 180 60 15)

START=$(date +%s); END=$(( START + TOTAL_DELAY )); EXTENDED_ON_IDLE=false

while :; do
  $CANCELLED && { say; say "Cancelled."; notify "Cancelled" "The scheduled $MODE was cancelled."; exit 0; }
  NOW=$(date +%s); REMAIN=$(( END - NOW )); (( REMAIN < 0 )) && REMAIN=0

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

  (( REMAIN == 10 )) && notify_final "Final warning: 10s" "Executing $MODE in 10 seconds."

  h=$(( REMAIN / 3600 )); m=$(( (REMAIN % 3600) / 60 )); s=$(( REMAIN % 60 ))
  progress_line "$h" "$m" "$s"

  if (( REMAIN == 0 )); then
    if $IDLE_SUPPORTED && ! $EXTENDED_ON_IDLE; then
      HINT="$(idle_hint)"
      if [ "$HINT" = "yes" ]; then
        EXTENDED_ON_IDLE=true; END=$(( $(date +%s) + 300 ))
        say; say "Timer expired during idle; adding +5 minutes."
        notify "Idle detected" "Timer expired during idle. Added +5 minutes before $MODE."
        sleep 1; continue
      fi
    fi
    break
  fi
  sleep 1
done

$QUIET || $SILENCE_OUTPUT || { [ -t 1 ] && echo; }
say "Time is up! Executing $MODE now..."
if [ "$MODE" = "reboot" ]; then notify "Executing reboot" "Now."; sudo systemctl reboot
else notify "Executing shutdown" "Now."; sudo systemctl poweroff
fi

