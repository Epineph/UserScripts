#!/usr/bin/env bash
# pipfast — optimized pip installer (script)

# Ensure help gate and viewer are available for non-interactive calls
[ -r "$HOME/.config/shell/cli_help.sh" ]  && . "$HOME/.config/shell/cli_help.sh"
[ -r "$HOME/.config/shell/helpout.bash" ] && . "$HOME/.config/shell/helpout.bash"

cli_help -t "pipfast — optimized installer" -l md "$@" <<'HLP' || exit 0
# pipfast — optimized pip installer

Usage:
  pipfast <pkg1> [pkg2 ...]
  pipfast -h | --help | help

Behavior:
  - Upgrades: pip, wheel, setuptools
  - Installs with flags:
      --upgrade --no-cache-dir --prefer-binary --timeout=60
HLP

python -m pip install -U pip wheel setuptools || exit 1
python -m pip install --upgrade --no-cache-dir --prefer-binary --timeout=60 "$@"
