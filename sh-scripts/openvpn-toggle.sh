#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# nm-vpn: Small NetworkManager VPN helper (up/down/toggle/status).
#
# Default connection name:
#   proton-nl-free30
#
# Usage:
#   nm-vpn                  # toggle (default)
#   nm-vpn --up             # bring up
#   nm-vpn --down           # bring down
#   nm-vpn --status         # print status
#   nm-vpn --name NAME      # override connection name
#   nm-vpn -h|--help        # help
#
# Environment:
#   VPN_CONN   Default connection name if --name is not provided.
#   HELP_PAGER Pager command for --help (defaults to "less -R" or "cat").
#
# Exit codes:
#   0 success
#   1 operational error
#   2 usage error
# -----------------------------------------------------------------------------

set -euo pipefail

VPN_CONN_DEFAULT="proton-nl-free30"

function die() {
	printf 'nm-vpn: %s\n' "$*" >&2
	exit 1
}

function usage() {
	local pager
	pager="${HELP_PAGER:-}"

	if [[ -z "$pager" ]]; then
		if command -v less >/dev/null 2>&1; then
			pager='less -R'
		else
			pager='cat'
		fi
	fi

	cat <<'EOF' | bash -c "$pager"
nm-vpn: Small NetworkManager VPN helper (up/down/toggle/status)

Usage:
  nm-vpn                  Toggle VPN connection (default)
  nm-vpn --up             Bring VPN up
  nm-vpn --down           Bring VPN down
  nm-vpn --status         Print status ("up" or "down")
  nm-vpn --name NAME      Use a specific NM connection name
  nm-vpn -h|--help        Show this help

Environment:
  VPN_CONN                Default NM connection name if --name not provided
  HELP_PAGER              Pager for help output (default: "less -R" or "cat")

Examples:
  nm-vpn --status
  nm-vpn --name proton-nl-free30 --down
EOF
}

function require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

function is_vpn_active() {
	local name
	name="$1"

	# Exit 0 if NAME is active and of TYPE "vpn", else exit 1.
	nmcli -t -f NAME,TYPE con show --active 2>/dev/null |
		awk -F: -v n="$name" '$1==n && $2=="vpn"{found=1} END{exit !found}'
}

function con_up() {
	local name
	name="$1"

	nmcli connection up "$name" >/dev/null
}

function con_down() {
	local name
	name="$1"

	nmcli connection down "$name" >/dev/null
}

function con_status() {
	local name
	name="$1"

	if is_vpn_active "$name"; then
		printf 'up\n'
	else
		printf 'down\n'
	fi
}

function main() {
	require_cmd nmcli
	require_cmd awk

	local action name
	action="toggle"
	name="${VPN_CONN:-$VPN_CONN_DEFAULT}"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--up)
			action="up"
			shift
			;;
		--down)
			action="down"
			shift
			;;
		--toggle)
			action="toggle"
			shift
			;;
		--status)
			action="status"
			shift
			;;
		--name)
			name="${2:-}"
			[[ -n "$name" ]] || {
				usage >&2
				exit 2
			}
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			printf 'nm-vpn: unknown option: %s\n' "$1" >&2
			usage >&2
			exit 2
			;;
		esac
	done

	case "$action" in
	up)
		con_up "$name" || die "failed to bring up: $name"
		;;
	down)
		con_down "$name" || die "failed to bring down: $name"
		;;
	status)
		con_status "$name"
		;;
	toggle)
		if is_vpn_active "$name"; then
			con_down "$name" || die "failed to bring down: $name"
		else
			con_up "$name" || die "failed to bring up: $name"
		fi
		;;
	*)
		die "internal error: unknown action: $action"
		;;
	esac
}

main "$@"
