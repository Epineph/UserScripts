# 1) Pretty printer: bat with your defaults, fallback to cat
sudo tee /usr/local/bin/batwrap >/dev/null <<'EOF'
#!/usr/bin/env bash
# batwrap — pretty-printer wrapper for scripts (falls back to cat).
# Honors BATWRAP_DEFAULT_OPTS if set; otherwise uses your preferred defaults.

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
EOF
sudo chmod 755 /usr/local/bin/batwrap

# 2) Help renderer: reads stdin and pretty-prints as Markdown by default
sudo tee /usr/local/bin/helpout >/dev/null <<'EOF'
#!/usr/bin/env bash
# helpout — render help from STDIN with batwrap (Markdown by default).

set -Eeuo pipefail
LANG_ARG="-l" ; LANG_VAL="md"

# Allow: helpout [-l <lang>] [--] <(ignored; reads stdin)>
if [[ "${1:-}" == "-l" && -n "${2:-}" ]]; then
  LANG_VAL="$2"
  shift 2
fi

if command -v batwrap >/dev/null 2>&1; then
  exec batwrap "$LANG_ARG" "$LANG_VAL"
elif command -v bat >/dev/null 2>&1; then
  # Backup path if batwrap vanished
  BAT_OPTS_DEFAULT='--style=grid,header,snip --italic-text=always --theme=gruvbox-dark --squeeze-blank --squeeze-limit=2 --force-colorization --terminal-width=auto --tabs=2 --paging=never --chop-long-lines'
  # shellcheck disable=SC2086
  exec bat $BAT_OPTS_DEFAULT "$LANG_ARG" "$LANG_VAL"
else
  exec cat
fi
EOF
sudo chmod 755 /usr/local/bin/helpout

