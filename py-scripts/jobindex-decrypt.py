#!/usr/bin/env bash

set -euo pipefail

#-----------------------------------------------------------------------------
# jobindex-scrape-wrapper
#
# Decrypt credentials only when needed, run the scraper, then clear secrets.
#-----------------------------------------------------------------------------

function cleanup() {
  unset JOBSITE_USERNAME || true
  unset JOBSITE_PASSWORD || true
}

trap cleanup EXIT

username_file="${HOME}/.secrets/jobindex_username.gpg"
password_file="${HOME}/.secrets/jobindex_password.gpg"

if [[ ! -f "${username_file}" ]]; then
  printf 'Missing file: %s\n' "${username_file}" >&2
  exit 1
fi

if [[ ! -f "${password_file}" ]]; then
  printf 'Missing file: %s\n' "${password_file}" >&2
  exit 1
fi

JOBSITE_USERNAME="$(
  gpg --quiet --decrypt "${username_file}"
)"

JOBSITE_PASSWORD="$(
  gpg --quiet --decrypt "${password_file}"
)"

export JOBSITE_USERNAME
export JOBSITE_PASSWORD

exec python "$HOME/repos/jobindex_scraper/jobindex_scraper.py" "$@"
