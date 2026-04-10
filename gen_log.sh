#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="$HOME/repos/generate_install_command"

[[ -d "$LOG_DIR" ]] || {
  printf 'Error: directory does not exist: %s\n' "$LOG_DIR" >&2
  exit 1
}

[[ $# -gt 0 ]] || {
  printf 'Usage: %s <command> [args ...]\n' "${0##*/}" >&2
  exit 1
}

latest_num=0

shopt -s nullglob
for f in "$LOG_DIR"/output_*.txt; do
  base="${f##*/}"
  num="${base#output_}"
  num="${num%.txt}"
  [[ "$num" =~ ^[0-9]+$ ]] || continue
  (( num > latest_num )) && latest_num="$num"
done
shopt -u nullglob

new_num=$((latest_num + 1))
output_file="${LOG_DIR}/output_${new_num}.txt"

printf 'Running command:'
printf ' %q' "$@"
printf '\n'

quoted_command="$(printf '%q ' "$@")"
script -q -c "$quoted_command" "$output_file"

printf 'Output has been logged to: %s\n' "$output_file"
