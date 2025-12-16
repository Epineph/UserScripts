#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

#------------------------------------------------------------------------------
# hyprlock-pamfix
#
# Fixes the common "pam_authentication_failed even with correct password"
# behavior on Hyprland/Arch by:
#   1) Ensuring hyprlock ignores empty submissions (prevents pam_faillock trips).
#   2) Optionally resetting faillock counters for the current user.
#
# References:
#   - hyprlock option: general:ignore_empty_input :contentReference[oaicite:2]{index=2}
#   - Arch default: pam_faillock lockout after failed unlocks :contentReference[oaicite:3]{index=3}
#------------------------------------------------------------------------------

function _pager() {
	if [[ -n "${HELP_PAGER:-}" ]]; then
		eval "$HELP_PAGER"
	elif command -v less >/dev/null 2>&1; then
		less -R
	else
		cat
	fi
}

function _help() {
	cat <<'USAGE' | _pager
# hyprlock-pamfix

## Synopsis
hyprlock-pamfix [--reset-faillock] [--status] [--no-edit] [-h|--help]

## What it does
- Ensures `ignore_empty_input = true` in:
  ~/.config/hypr/hyprlock.conf

This prevents accidental empty submits (space/enter/backspace on wake)
from counting as failed PAM attempts, which would trigger pam_faillock.

- Optionally resets PAM faillock counters for your user.

## Options
--reset-faillock   Run: sudo faillock --user "$USER" --reset
--status           Show: sudo faillock --user "$USER"
--no-edit          Do not modify hyprlock.conf (status-only usage)
-h, --help         Show this help

## Notes
If /etc/pam.d/hyprlock is missing, reinstall hyprlock:
  sudo pacman -S --needed --overwrite /etc/pam.d/hyprlock hyprlock pambase

USAGE
}

function _backup_file() {
	local f="$1"
	if [[ -f "$f" ]]; then
		cp -a -- "$f" "${f}.bak.$(date +%F_%H%M%S)"
	fi
}

function _ensure_ignore_empty_input() {
	local cfg="$1"
	mkdir -p -- "$(dirname -- "$cfg")"

	if [[ ! -f "$cfg" ]]; then
		cat <<'MINCFG' >"$cfg"
general {
  ignore_empty_input = true
}
MINCFG
		return 0
	fi

	_backup_file "$cfg"

	# 1) If ignore_empty_input exists anywhere, force it to true.
	if grep -Eq '^[[:space:]]*ignore_empty_input[[:space:]]*=' "$cfg"; then
		sed -E -i \
			's/^[[:space:]]*ignore_empty_input[[:space:]]*=.*/  ignore_empty_input = true/' \
			"$cfg"
		return 0
	fi

	# 2) If general { } exists, inject the key before its closing brace.
	if grep -Eq '^[[:space:]]*general[[:space:]]*\{' "$cfg"; then
		awk '
      BEGIN { in_general=0; injected=0 }
      /^[[:space:]]*general[[:space:]]*\{/ {
        in_general=1
        print
        next
      }
      in_general && /^[[:space:]]*\}[[:space:]]*$/ {
        if (!injected) {
          print "  ignore_empty_input = true"
          injected=1
        }
        in_general=0
        print
        next
      }
      { print }
    ' "$cfg" >"${cfg}.tmp"
		mv -- "${cfg}.tmp" "$cfg"
		return 0
	fi

	# 3) No general block: prepend one.
	{
		printf '%s\n' 'general {' \
			'  ignore_empty_input = true' \
			'}' \
			''
		cat -- "$cfg"
	} >"${cfg}.tmp"
	mv -- "${cfg}.tmp" "$cfg"
}

function main() {
	local do_reset="false"
	local do_status="false"
	local do_edit="true"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--reset-faillock) do_reset="true" ;;
		--status) do_status="true" ;;
		--no-edit) do_edit="false" ;;
		-h | --help)
			_help
			exit 0
			;;
		*)
			printf 'Error: unknown argument: %s\n' "$1" >&2
			printf 'Run: hyprlock-pamfix --help\n' >&2
			exit 2
			;;
		esac
		shift
	done

	local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprlock.conf"

	if [[ "$do_edit" == "true" ]]; then
		_ensure_ignore_empty_input "$cfg"
		printf '[OK] Ensured ignore_empty_input = true in %s\n' "$cfg"
	fi

	if [[ "$do_status" == "true" ]]; then
		sudo faillock --user "$USER" || true
	fi

	if [[ "$do_reset" == "true" ]]; then
		sudo faillock --user "$USER" --reset
		printf '[OK] Reset faillock counters for %s\n' "$USER"
	fi

	cat <<'NEXT'
Next:
  1) Lock manually: hyprlock -v
  2) Wake the screen (space/enter) and unlock normally.
If it still fails, run:
  sudo faillock --user "$USER"
NEXT
}

main "$@"
