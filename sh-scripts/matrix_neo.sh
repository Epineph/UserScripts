#!/usr/bin/env bash
# matrix_neo.sh
# ───────────────────────────────────────────────────────
# Wrapper to launch neo in “screensaver” mode with your flags.
# Falls back to $TERMINAL, or runs in-place if not set.
#
# Usage: matrix_neo.sh
# (no positional args; everything is baked in)

set -euo pipefail

# Your neo command and message:
cmd=(
  neo
  --colormode=256
  --fps=240
  --maxdpc=1
  -S 6
  --rippct=80
  --glitchpct=10
  --screensaver
  -m "IN SOVIET RUSSIA, COM‐PUTIN PC PROGRAMS YOU"
)

# If $TERMINAL is defined (e.g. alacritty, kitty), use it:
if [[ -n "${TERMINAL-}" ]]; then
  exec $TERMINAL -e "${cmd[@]}"
else
  exec "${cmd[@]}"
fi

