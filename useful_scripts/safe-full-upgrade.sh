#!/usr/bin/env bash
# safe-full-upgrade.sh — Full upgrade + GRUB refresh + guarded reboot/poweroff.
#
# Steps:
#   1. sudo new-mirrors
#   2. yay -Syyu --noconfirm
#   3. sudo mkinitcpio -P
#   4. sudo grub-install ...
#   5. sudo grub-mkconfig ...
#   6. Delay with notification + countdown (non-cancellable by default)
#   7. sudo systemctl <reboot|poweroff>
#
# Exit codes:
#   0  success
#   1  usage / input error
#   2  missing dependency
#   3  runtime failure

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
VERSION="0.2.0"

# ────────────────────────────── Defaults ──────────────────────────────
ACTION="reboot" # reboot | poweroff
DELAY="5m"      # human-friendly; parsed to seconds (default: 5 minutes)
CANCEL_ENABLED="false"

# ────────────────────────────── Help text ─────────────────────────────
function show_help() {
  local pager

  if [[ -n "${HELP_PAGER:-}" ]]; then
    pager="$HELP_PAGER"
  else
    if command -v less >/dev/null 2>&1; then
      pager="less -R"
    else
      pager="cat"
    fi
  fi

  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
${SCRIPT_NAME} — full system upgrade with guarded reboot/poweroff
Version: ${VERSION}

USAGE:
  ${SCRIPT_NAME} [OPTIONS]

DESCRIPTION:
  Runs a full Arch-style upgrade and bootloader refresh:

    1) sudo new-mirrors
    2) yay -Syyu --noconfirm
    3) sudo mkinitcpio -P
    4) sudo grub-install --target=x86_64-efi \\
           --efi-directory=/efi --bootloader-id=GRUB --recheck
    5) sudo grub-mkconfig -o /boot/grub/grub.cfg
    6) Delay with desktop notification and terminal countdown
    7) sudo systemctl <reboot|poweroff>

  By default:
    • Final action: reboot
    • Delay       : 5 minutes
    • Cancellation: DISABLED (Ctrl+C will NOT stop the reboot/poweroff)

OPTIONS:
  -a, --action <reboot|poweroff>
      Final systemctl action. Default: reboot

  -d, --delay <DURATION>
      Delay before the final action. Accepted forms:
        • Seconds only:   120
        • Minutes:        2m
        • Hours:          1h
        • Mixed:          2m30s, 1h5m, 1h5m3s, etc.
      Internally converted to total seconds (shown in both total seconds
      and h/m/s form). Default: 5m

  --allow-cancel
      Allow cancellation of the final action with Ctrl+C during the
      countdown. By default, cancellation is disabled.

  -h, --help
      Show this help and exit.

EXAMPLES:
  # Default: full upgrade, then reboot after 5 minutes, no cancellation.
  ${SCRIPT_NAME}

  # Full upgrade, then power off after 2 minutes 39 seconds, cancellable.
  ${SCRIPT_NAME} --action poweroff --delay 2m39s --allow-cancel

  # Full upgrade, then reboot after exactly 159 seconds, cancellable.
  ${SCRIPT_NAME} --delay 159 --allow-cancel

NOTES:
  • You must be able to use sudo for the commands invoked.
  • Desktop notifications require 'notify-send' (libnotify, mako, etc.).
EOF

  # shellcheck disable=SC2086
  "$pager" "$tmp"
  rm -f "$tmp"
}

# ────────────────────────────── Utilities ─────────────────────────────
function die() {
  echo "[$SCRIPT_NAME] ERROR: $*" >&2
  exit 3
}

function require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[$SCRIPT_NAME] Missing required command: $cmd" >&2
    exit 2
  fi
}

function notify() {
  local title="$1"
  local body="${2:-}"

  if command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$body" || true
  fi
}

# ─────────────────────── Delay parsing (h/m/s → s) ────────────────────
# Accepts:
#   - "159"       → 159
#   - "2m"        → 120
#   - "2m39s"     → 159
#   - "1h5m3s"    → 3903
function parse_delay_to_seconds() {
  local input="$1"
  local total=0

  # Pure integer -> seconds
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    echo "$input"
    return 0
  fi

  # General pattern: optional h, optional m, optional s, in that order.
  if ! [[ "$input" =~ ^([0-9]+h)?([0-9]+m)?([0-9]+s)?$ ]]; then
    echo "[$SCRIPT_NAME] Invalid delay format: $input" >&2
    echo "Use e.g. 120, 2m, 2m30s, 1h5m, 1h5m3s." >&2
    exit 1
  fi

  local h=0 m=0 s=0

  if [[ "$input" =~ ([0-9]+)h ]]; then
    h="${BASH_REMATCH[1]}"
  fi
  if [[ "$input" =~ ([0-9]+)m ]]; then
    m="${BASH_REMATCH[1]}"
  fi
  if [[ "$input" =~ ([0-9]+)s ]]; then
    s="${BASH_REMATCH[1]}"
  fi

  total=$((h * 3600 + m * 60 + s))
  echo "$total"
}

# ────────────────────────────── Signals ───────────────────────────────
function on_sigint() {
  echo
  if [[ "$CANCEL_ENABLED" != "true" ]]; then
    echo "[$SCRIPT_NAME] Cancellation is DISABLED; countdown continues."
    return
  fi

  echo "[$SCRIPT_NAME] Countdown cancelled. No ${ACTION} will occur."
  notify "System ${ACTION} cancelled" \
    "Countdown aborted. No ${ACTION} will be performed."
  exit 0
}

trap on_sigint INT

# ────────────────────────────── Args ──────────────────────────────────
function parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -a | --action)
      [[ $# -ge 2 ]] || {
        echo "[$SCRIPT_NAME] --action requires a value." >&2
        exit 1
      }
      ACTION="$2"
      shift 2
      ;;
    -d | --delay)
      [[ $# -ge 2 ]] || {
        echo "[$SCRIPT_NAME] --delay requires a value." >&2
        exit 1
      }
      DELAY="$2"
      shift 2
      ;;
    --allow-cancel)
      CANCEL_ENABLED="true"
      shift
      ;;
    -h | --help)
      show_help
      exit 0
      ;;
    *)
      echo "[$SCRIPT_NAME] Unknown argument: $1" >&2
      echo "Try: ${SCRIPT_NAME} --help" >&2
      exit 1
      ;;
    esac
  done

  case "$ACTION" in
  reboot | poweroff) ;;
  *)
    echo "[$SCRIPT_NAME] Invalid --action: $ACTION" >&2
    echo "Use: reboot | poweroff" >&2
    exit 1
    ;;
  esac

  # Convert DELAY to pure seconds here.
  local seconds
  seconds="$(parse_delay_to_seconds "$DELAY")"
  DELAY="$seconds"
}

# ───────────────────── Countdown + final systemctl ────────────────────
function format_hms() {
  local total="$1"
  local h=$((total / 3600))
  local rem=$((total % 3600))
  local m=$((rem / 60))
  local s=$((rem % 60))

  local parts=()
  if ((h > 0)); then
    parts+=("${h}h")
  fi
  if ((m > 0)); then
    parts+=("${m}m")
  fi
  if ((s > 0 || total == 0)); then
    parts+=("${s}s")
  fi

  printf '%s' "${parts[*]}"
}

function countdown_and_act() {
  local remaining="$DELAY"
  local cmd=(sudo systemctl "$ACTION")

  local pretty
  pretty="$(format_hms "$remaining")"

  if ((remaining <= 0)); then
    echo "[$SCRIPT_NAME] No delay configured; executing: ${cmd[*]}"
    notify "System ${ACTION} now" \
      "Executing: systemctl ${ACTION} (no countdown)."
    "${cmd[@]}"
    return
  fi

  echo
  echo "[$SCRIPT_NAME] System will ${ACTION} in ${remaining} seconds (~${pretty})."
  if [[ "$CANCEL_ENABLED" == "true" ]]; then
    echo "[$SCRIPT_NAME] Ctrl+C will CANCEL the ${ACTION}."
  else
    echo "[$SCRIPT_NAME] Cancellation is DISABLED (Ctrl+C will NOT stop it)."
  fi

  notify "System ${ACTION} scheduled" \
    "System will ${ACTION} in ${remaining}s (~${pretty})."

  while ((remaining > 0)); do
    printf '\r[%s] %4ds remaining before %s...' \
      "$SCRIPT_NAME" "$remaining" "$ACTION"
    sleep 1
    ((remaining--))
  done
  echo

  notify "System ${ACTION}" \
    "Proceeding with: systemctl ${ACTION}."
  echo "[$SCRIPT_NAME] Executing: ${cmd[*]}"
  "${cmd[@]}"
}

# ─────────────────────────── Main workflow ────────────────────────────
function main() {
  parse_args "$@"

  require_cmd sudo
  require_cmd yay
  require_cmd mkinitcpio
  require_cmd grub-install
  require_cmd grub-mkconfig
  require_cmd systemctl

  echo "[$SCRIPT_NAME] Starting full upgrade workflow."
  echo "  Final action   : $ACTION"
  echo "  Delay (seconds): $DELAY"
  echo "  Cancellation   : $CANCEL_ENABLED"
  echo

  echo "[$SCRIPT_NAME] 1/5: Updating mirrors (sudo new-mirrors)..."
  sudo new-mirrors

  echo "[$SCRIPT_NAME] 2/5: Upgrading packages (yay -Syyu --noconfirm)..."
  yay -Syyu --noconfirm

  echo "[$SCRIPT_NAME] 3/5: Rebuilding initramfs (sudo mkinitcpio -P)..."
  sudo mkinitcpio -P

  echo "[$SCRIPT_NAME] 4/5: Reinstalling GRUB to EFI..."
  sudo grub-install --target=x86_64-efi \
    --efi-directory=/efi \
    --bootloader-id=GRUB \
    --recheck

  echo "[$SCRIPT_NAME] 5/5: Regenerating GRUB config..."
  sudo grub-mkconfig -o /boot/grub/grub.cfg

  echo
  echo "[$SCRIPT_NAME] Core operations completed successfully."
  echo "[$SCRIPT_NAME] Entering delay before systemctl $ACTION."
  countdown_and_act
}

main "$@"
