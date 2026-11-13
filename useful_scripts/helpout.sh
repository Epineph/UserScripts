#!/usr/bin/env bash
# helpout — render help from stdin with batwrap (Markdown by default).
set -Eeuo pipefail
LANG_ARG="-l"; LANG_VAL="md"
if [[ "${1:-}" == "-l" && -n "${2:-}" ]]; then
  LANG_VAL="$2"; shift 2
fi
if command -v batwrap >/dev/null 2>&1; then
  exec batwrap "$LANG_ARG" "$LANG_VAL"
elif command -v bat >/dev/null 2>&1; then
  BAT_OPTS_DEFAULT='--style=grid,header,snip --italic-text=always --theme=gruvbox-dark --squeeze-blank --squeeze-limit=2 --force-colorization --terminal-width=auto --tabs=2 --paging=never --chop-long-lines'
  # shellcheck disable=SC2086
  exec bat $BAT_OPTS_DEFAULT "$LANG_ARG" "$LANG_VAL"
else
  exec cat
fi
