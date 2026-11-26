#!/usr/bin/env bash

(
  set -o pipefail
  umask 077
  cd -P -- "$HOME/.config" || exit 1

  day=$(date --iso-8601) || exit 1
  base="$HOME/Documents/fd-results-absolute-$day"
  list="$base.txt"
  archive="$base.7z"

  if [[ -e "$archive" || -L "$archive" ]]; then
    printf 'Archive already exists: %s\n' "$archive" >&2
    exit 1
  fi

  fd -a --type f --color never \
    -e toml -e lua -e ghostty -e json -e yml \
    --exclude microsoft-edge-dev --exclude yazi --exclude hypr --exclude R \
    --exclude google-chrome --exclude BraveSoftware \
    --exclude Code/User/globalStorage --exclude Code/User/History \
    --exclude Code/User/workspaceStorage --exclude swaync \
    --exclude wallust-backup-back-up_1115_2132 --exclude quickshell \
    --exclude quickshell-backup-back-up_1115_2132 \
    --exclude Code/agent-host --exclude swaync-backup-back-up_1115_2132 |
    tee "$list" || exit 1

  if [[ ! -s "$list" ]]; then
    printf 'No matching files.\n' >&2
    exit 1
  fi

  # Give 7-Zip paths relative to ~/.config to preserve its directory layout.
  relative_list=$(mktemp) || exit 1
  trap 'rm -f -- "$relative_list"' EXIT
  while IFS= read -r file_path; do
    printf '%s\n' "${file_path#"$PWD"/}" || exit 1
  done < "$list" > "$relative_list" || exit 1

  sudo 7z a -p -mhe=on -spd "$archive" "@$relative_list" &&
    printf '\nFile list: %s\nArchive:   %s\n' "$list" "$archive"
)
