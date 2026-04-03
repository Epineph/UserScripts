#!/usr/bin/env bash
# Refresh Arch mirrorlist, tuned for Copenhagen / Nordic region.

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Countries closest (network-wise) to Copenhagen.
countries=(
	Denmark
	Sweden
	Norway
	Finland
	Germany
	Netherlands
)

# Maximum allowed mirror age in hours.
max_age_hours=12

# How many mirrors to keep in the final mirrorlist.
mirrors_to_keep=12

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function error() {
	printf 'reflector-refresh: %s\n' "$*" >&2
}

function build_countries_list() {
	local list
	list=$(
		IFS=,
		echo "${countries[*]}"
	)
	printf '%s\n' "$list"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function main() {
	if ! command -v reflector >/dev/null 2>&1; then
		error "reflector is not installed."
		exit 1
	fi

	local countries_list
	countries_list=$(build_countries_list)

	local sudo_cmd=()
	if [[ $EUID -ne 0 ]]; then
		sudo_cmd=(sudo)
	fi

	"${sudo_cmd[@]}" reflector --verbose \
		--country "$countries_list" \
		--age "$max_age_hours" \
		--protocol https \
		--ipv4 \
		--sort rate \
		--number "$mirrors_to_keep" \
		--connection-timeout 5 \
		--download-timeout 10 \
		--cache-timeout 0 \
		--threads 4 \
		--save /etc/pacman.d/mirrorlist
}

main "$@"
