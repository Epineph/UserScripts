#!/usr/bin/env bash

#===============================================================================
# ssh-time
#
# Wrapper around ssh-agent + ssh-add that:
#   • Sets a key lifetime using hours/minutes/seconds
#   • Prints a human-readable duration
#   • Prints the same duration in total seconds
#   • Shows current time and when the key will expire (with timezone info)
#   • Hides the key comment (e.g. email) unless --sudo is provided and succeeds
#
# Usage:
#   ssh-time [-s | --seconds N] [-m | --minutes N] [-h | --hours N]
#            [--key PATH] [--sudo]
#
# Defaults:
#   --key defaults to: $HOME/.ssh/id_rsa
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

#------------------------------------------------------------------------------
# Usage
#------------------------------------------------------------------------------
function usage() {
	echo "Usage: $0 [-s | --seconds N] [-m | --minutes N] [-h | --hours N]"
	echo "          [--key PATH] [--sudo]"
	echo
	echo "Provide at least one of -s/-m/-h to specify time."
	echo "--key   Path to private key (default: \$HOME/.ssh/id_rsa)."
	echo "--sudo  Require sudo auth and display key comment (e.g. email)."
	exit 1
}

#------------------------------------------------------------------------------
# Parse arguments
#------------------------------------------------------------------------------
seconds=0
minutes=0
hours=0
key_path="$HOME/.ssh/id_rsa"
SHOW_COMMENT=0

while [[ "$#" -gt 0 ]]; do
	case "$1" in
	-s | --seconds)
		[[ $# -lt 2 ]] && usage
		seconds="$2"
		shift 2
		;;
	-m | --minutes)
		[[ $# -lt 2 ]] && usage
		minutes="$2"
		shift 2
		;;
	-h | --hours)
		[[ $# -lt 2 ]] && usage
		hours="$2"
		shift 2
		;;
	--key)
		[[ $# -lt 2 ]] && usage
		key_path="$2"
		shift 2
		;;
	--sudo)
		SHOW_COMMENT=1
		shift
		;;
	*)
		usage
		;;
	esac
done

# Validate inputs
if [[ "$seconds" -eq 0 && "$minutes" -eq 0 && "$hours" -eq 0 ]]; then
	usage
fi

if ! [[ "$seconds" =~ ^[0-9]+$ && "$minutes" =~ ^[0-9]+$ && "$hours" =~ ^[0-9]+$ ]]; then
	echo "All time values must be non-negative integers." >&2
	exit 1
fi

#------------------------------------------------------------------------------
# Calculate total time in seconds
#------------------------------------------------------------------------------
total_seconds=$((seconds + minutes * 60 + hours * 3600))
if ((total_seconds <= 0)); then
	echo "Total time must be greater than zero." >&2
	exit 1
fi

#------------------------------------------------------------------------------
# Format and print time
#------------------------------------------------------------------------------
function format_time() {
	local total="$1"
	local h m s

	h=$((total / 3600))
	m=$(((total % 3600) / 60))
	s=$((total % 60))

	if ((total < 60)); then
		printf "Time: %d seconds (%.2f minutes, %d seconds in total)\n" \
			"$total" "$(bc -l <<<"$total / 60")" "$total"
	elif ((total < 3600)); then
		printf "Time: %d minutes, %d seconds (%.2f hours, %d seconds in total)\n" \
			"$m" "$s" "$(bc -l <<<"$total / 3600")" "$total"
	else
		printf "Time: %d hours, %d minutes, %d seconds (%d seconds in total)\n" \
			"$h" "$m" "$s" "$total"
	fi
}

#------------------------------------------------------------------------------
# Helper: print identity line with or without comment
#------------------------------------------------------------------------------
function print_identity_info() {
	local key="$1"

	# By default we hide the comment and do not touch sudo at all
	if ((SHOW_COMMENT == 0)); then
		echo "Identity added: $key (comment hidden; use --sudo to display)"
		return
	fi

	# SHOW_COMMENT == 1: require sudo validation first
	if ! sudo -v 2>/dev/null; then
		echo "⚠ sudo authentication failed; hiding key comment."
		echo "Identity added: $key (comment hidden)"
		return
	fi

	# Try to derive comment from the public key *in the user context*, not /root
	local pub="$key.pub"
	local comment=""

	if [[ -f "$pub" ]]; then
		# ssh-keygen -lf file => "... fingerprint  comment  (type)"
		# We strip the last field "(type)" and keep the comment.
		comment="$(ssh-keygen -lf "$pub" 2>/dev/null |
			awk '{for (i=3; i<NF; i++) printf (i==3?$i:OFS $i)}')"
	fi

	if [[ -n "$comment" ]]; then
		echo "Identity added: $key ($comment)"
	else
		echo "Identity added: $key (no comment found)"
	fi
}

#------------------------------------------------------------------------------
# Start ssh-agent and add key with timeout
#------------------------------------------------------------------------------
eval "$(ssh-agent -s)"

# Quiet mode: suppress ssh-add's own "Identity added" line (with email)
ssh-add -q -t "$total_seconds" "$key_path"

# Our controlled identity line
print_identity_info "$key_path"

#------------------------------------------------------------------------------
# Report duration in a richer form
#------------------------------------------------------------------------------
format_time "$total_seconds"

#------------------------------------------------------------------------------
# Show current time and expiry time (with timezone)
#------------------------------------------------------------------------------
current_epoch="$(date +%s)"
expiry_epoch=$((current_epoch + total_seconds))

current_str="$(date '+%Y-%m-%d %H:%M:%S %Z (UTC%z)')"
expiry_str="$(date -d "@$expiry_epoch" '+%Y-%m-%d %H:%M:%S %Z (UTC%z)')"

echo "Current time : $current_str"
echo "Expires at   : $expiry_str"
