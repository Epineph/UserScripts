#!/usr/bin/env bash
set -euo pipefail

read -rp 'Jobindex username: ' JOBSITE_USERNAME
read -rsp 'Jobindex password: ' JOBSITE_PASSWORD
printf '\n'

export JOBSITE_USERNAME
export JOBSITE_PASSWORD

exec python scraper.py "$@"
