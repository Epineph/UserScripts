#!/usr/bin/env bash
# batwrap — pretty-printer wrapper (falls back to cat).
set -Eeuo pipefail
BAT_BIN="$(command -v bat || true)"
BAT_OPTS_DEFAULT='--style=grid,header,snip --italic-text=always --theme=gruvbox-dark --squeeze-blank --squeeze-limit=2 --force-colorization --terminal-width=auto --tabs=2 --paging=never --chop-long-lines'
BATWRAP_DEFAULT_OPTS="${BATWRAP_DEFAULT_OPTS:-$BAT_OPTS_DEFAULT}"
if [[ -n "$BAT_BIN" ]]; then
  # shellcheck disable=SC2086
  exec "$BAT_BIN" $BATWRAP_DEFAULT_OPTS "$@"
else
  exec cat "$@"
fi
