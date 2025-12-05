#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

countries=(
	Denmark
	Germany
	Sweden
	Norway
)

countries_list=$(
	IFS=,
	echo "${countries[*]}"
)

if ! command -v reflector >/dev/null 2>&1; then
	echo "Error: reflector is not installed."
	>&2
	exit1
fi

sudo reflector --verbose \
	--country "$countries_list" \
	--age 24 \
	--latest 20 \
	--fastest 10 \
	--sort rate \
	--protocol https \
	--ipv4 \
	--connection-timeout 3 \
	--download-timeout 7 \
	--cache-timeout 0 \
	--threads 4 \
	--save /etc/pacman.d/mirrorlist
