#!/usr/bin/env bash

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
	--save "/etc/pacman.d/mirrorlist"
