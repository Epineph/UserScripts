#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Script: hypr-send-enter
# Purpose: Send an "Enter" (Return) key event via Wayland virtual keyboard.
#          Intended for Hyprland/wlroots when a physical Enter key misbehaves.
#
# Notes:
#   - Requires: wtype
#   - Works for Wayland apps (including terminals running under Wayland).
#   - Does NOT work for Linux TTYs (Ctrl+Alt+F*), because those bypass Wayland.
# -----------------------------------------------------------------------------

function _pager() {
  if [[ -n "${HELP_PAGER:-}" ]]; then
    printf '%s\n' "$HELP_PAGER"
    return 0
  fi
  if command -v less >/dev/null 2>&1; then
    printf '%s\n' "less -R"
    return 0
  fi
  printf '%s\n' "cat"
}

function _help() {
  cat <<'HELP' | eval "$(_pager)"
hypr-send-enter

USAGE
  hypr-send-enter [--kp] [--repeat N] [--delay-ms MS]
  hypr-send-enter -h | --help

DESCRIPTION
  Sends an Enter keypress to the currently focused Wayland surface using wtype.
  Default is "Return". With --kp it sends "KP_Enter" (numpad enter).

OPTIONS
  --kp            Send KP_Enter instead of Return.
  --repeat N      Send the key N times (default: 1).
  --delay-ms MS   Delay between repeats in milliseconds (default: 40).
  -h, --help      Show this help.

EXAMPLES
  hypr-send-enter
  hypr-send-enter --kp
  hypr-send-enter --repeat 3 --delay-ms 80
HELP
}

kp=0
repeat=1
delay_ms=40

while [[ $# -gt 0 ]]; do
  case "$1" in
  --kp)
    kp=1
    shift
    ;;
  --repeat)
    repeat="${2:?Missing value for --repeat}"
    shift 2
    ;;
  --delay-ms)
    delay_ms="${2:?Missing value for --delay-ms}"
    shift 2
    ;;
  -h | --help)
    _help
    exit 0
    ;;
  *)
    printf 'Error: unknown argument: %s\n' "$1" >&2
    printf 'Hint: use --help\n' >&2
    exit 2
    ;;
  esac
done

if ! command -v wtype >/dev/null 2>&1; then
  printf 'Error: wtype not found. Install it: sudo pacman -S wtype\n' >&2
  exit 127
fi

key="Return"
if [[ "$kp" -eq 1 ]]; then
  key="KP_Enter"
fi

# Send the key repeat times.
i=1
while [[ "$i" -le "$repeat" ]]; do
  wtype -k "$key" >/dev/null 2>&1 || {
    printf 'Error: wtype failed to send key: %s\n' "$key" >&2
    exit 1
  }
  sleep "$(
    python - <<PY
ms=${delay_ms}
print(max(ms,0)/1000)
PY
  )"
  i=$((i + 1))
done
