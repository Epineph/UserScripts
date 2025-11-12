#!/bin/bash
# AUR Popularity Enumeration Script (Bash Version)
# Requires: curl, jq

if [ -z "$1" ]; then
  echo "Usage: $0 <search_term>"
  exit 1
fi

SEARCH_TERM="$1"

# Query the AUR API and sort packages by 'Votes'
curl -s "https://aur.archlinux.org/rpc/?v=5&type=search&arg=${SEARCH_TERM}" | \
jq -r '.results | sort_by(.Votes) | reverse | to_entries[] | "\(.key + 1): \(.value.Name) (\(.value.Votes) votes)"'

