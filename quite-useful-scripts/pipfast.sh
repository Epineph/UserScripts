#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# pipfast — optimized pip installer (script variant)
# ──────────────────────────────────────────────────────────────────────────────

# Make the help gate available even outside interactive shells:
HELP_LIB="${HELP_LIB:-$HOME/.config/shell/cli_help.zsh}"
[[ -r "$HELP_LIB" ]] && source "$HELP_LIB"

cli_help -t "pipfast — optimized installer" -l md "$@" << 'HLP' || exit 0
# pipfast — optimized pip installer

Usage:
  pipfast <pkg1> [pkg2 ...]
  pipfast -h | --help | help
HLP

python -m pip install -U pip wheel setuptools || exit 1
python -m pip install --upgrade --no-cache-dir --prefer-binary --timeout=60 "$@"
