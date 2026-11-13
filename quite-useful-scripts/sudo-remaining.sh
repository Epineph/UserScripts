#!/usr/bin/env bash
#==============================================================================
# sudo-remaining
#
# Show remaining validity of the current sudo authentication timestamp.
#
# - Uses /run/sudo/ts/$UID to locate the active sudo timestamp file
# - Infers timeout from `sudo -l` (falls back to 5 minutes if not visible)
# - Prints remaining time either as HH:MM:SS (default) or raw seconds
#==============================================================================

set -euo pipefail
IFS=$'\n\t'

#------------------------------------------------------------------------------
# Helper: pager for help output
# Uses HELP_PAGER if set; otherwise prefers `less -R`, then falls back to `cat`.
#------------------------------------------------------------------------------
function _help_pager() {
	local pager
	pager="${HELP_PAGER:-}"

	if [[ -z "$pager" ]]; then
		if command -v less >/dev/null 2>&1; then
			pager='less -R'
		else
			pager='cat'
		fi
	fi

	eval "$pager"
}

#------------------------------------------------------------------------------
# Print help
#------------------------------------------------------------------------------
function print_help() {
	_help_pager <<'EOF'
sudo-remaining
===============

Show the remaining validity of the current sudo authentication timestamp.

Usage:
  sudo-remaining [options]

Options:
  -r, --raw-seconds
      Print remaining time as raw seconds (integer).

  -f, --show-file
      Print the path of the timestamp file used (on stderr).

  -h, --help
      Show this help text.

Exit codes:
  0  Success; remaining time shown (possibly 00:00:00 / 0).
  1  No active sudo timestamp found (you have not authenticated yet).
  2  Some other error (missing /run/sudo/ts, stat failure, etc.).

Notes:
  - This script *does not* refresh or change sudo timestamps.
  - It only inspects the timestamp file's modification time.
  - Timeout is derived from `sudo -l` if possible; otherwise default 5 minutes.
EOF
}

#------------------------------------------------------------------------------
# Format seconds as HH:MM:SS
#------------------------------------------------------------------------------
function format_hms() {
	local total h m s
	total="$1"

	if ((total < 0)); then
		total=0
	fi

	h=$((total / 3600))
	m=$(((total % 3600) / 60))
	s=$((total % 60))

	printf '%02d:%02d:%02d\n' "$h" "$m" "$s"
}

#------------------------------------------------------------------------------
# Get sudo timestamp timeout (minutes)
# Tries to parse from `sudo -l`; falls back to 5 if not present.
#------------------------------------------------------------------------------
function get_timeout_minutes() {
	local out timeout
	timeout=''

	if out="$(sudo -l 2>/dev/null)"; then
		timeout="$(
			printf '%s\n' "$out" |
				grep -Eo 'timestamp_timeout=[0-9]+' |
				tail -n 1 |
				cut -d= -f2 || true
		)"
	fi

	if [[ -z "$timeout" ]]; then
		timeout=5
	fi

	printf '%s\n' "$timeout"
}

#------------------------------------------------------------------------------
# Find the active sudo timestamp file for this UID.
# Prefers "global" if present; otherwise first regular file.
#------------------------------------------------------------------------------
function find_timestamp_file() {
	local dir file
	dir="/run/sudo/ts/${UID}"

	if [[ ! -d "$dir" ]]; then
		return 1
	fi

	if [[ -f "${dir}/global" ]]; then
		printf '%s\n' "${dir}/global"
		return 0
	fi

	# Fallback: first regular file in the directory
	file="$(
		find "$dir" -maxdepth 1 -type f ! -name '*.tmp' 2>/dev/null |
			head -n 1
	)"

	[[ -n "$file" ]] || return 1

	printf '%s\n' "$file"
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
function sudo_remaining_main() {
	local raw_seconds show_file
	raw_seconds=0
	show_file=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
		-r | --raw-seconds)
			raw_seconds=1
			shift
			;;
		-f | --show-file)
			show_file=1
			shift
			;;
		-h | --help)
			print_help
			exit 0
			;;
		--)
			shift
			break
			;;
		-*)
			printf 'Error: unknown option: %s\n' "$1" >&2
			exit 2
			;;
		*)
			# No positional arguments supported
			printf 'Error: unexpected argument: %s\n' "$1" >&2
			exit 2
			;;
		esac
	done

	local tsfile timeout_min mtime now expiry remain

	if ! tsfile="$(find_timestamp_file)"; then
		printf 'No active sudo timestamp found; authenticate with sudo first.\n' >&2
		exit 1
	fi

	if ((show_file)); then
		printf 'Using timestamp file: %s\n' "$tsfile" >&2
	fi

	timeout_min="$(get_timeout_minutes)"

	mtime="$(stat -c '%Y' "$tsfile")"
	now="$(date +%s)"

	expiry=$((mtime + timeout_min * 60))
	remain=$((expiry - now))

	if ((raw_seconds)); then
		if ((remain < 0)); then
			remain=0
		fi
		printf '%d\n' "$remain"
	else
		format_hms "$remain"
	fi
}

sudo_remaining_main "$@"
