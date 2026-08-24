#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_KEY_ID="3056513887B78AEB"
readonly DEFAULT_KEYSERVER="hkp://keyserver.ubuntu.com:80"
readonly KEYRING_URL="https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst"
readonly MIRRORLIST_URL="https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst"
readonly PACMAN_CONF="/etc/pacman.conf"
readonly MIRRORLIST="/etc/pacman.d/chaotic-mirrorlist"

KEYSERVER="$DEFAULT_KEYSERVER"
KEY_IDS=("$DEFAULT_KEY_ID")
MIRRORS=""
RESET=0
SYNC_MODE="sync"
PACMAN_CONFIRM_ARGS=()

usage() {
  cat <<'EOF'
chaotic-aur-refresh - refresh or repair the Chaotic-AUR pacman setup

Usage:
  chaotic-aur-refresh [options]
  chaotic-aur-reset [options]

Description:
  Re-applies the official Chaotic-AUR setup in a repeatable way:
    1. Initializes the pacman keyring if needed.
    2. Receives and locally signs the Chaotic-AUR primary key.
    3. Reinstalls chaotic-keyring and chaotic-mirrorlist from Chaotic-AUR.
    4. Populates the archlinux and chaotic pacman keyrings.
    5. Normalizes /etc/pacman.conf so [chaotic-aur] uses only:

         [chaotic-aur]
         Include = /etc/pacman.d/chaotic-mirrorlist

    6. Optionally filters /etc/pacman.d/chaotic-mirrorlist so only selected
       mirrors remain active.
    7. Optionally refreshes package databases or runs a full upgrade.

  chaotic-aur-refresh is for normal repair/reinstall work.
  chaotic-aur-reset does the same thing, but first deletes the configured
  Chaotic-AUR key(s) from the pacman keyring and removes the current
  chaotic-mirrorlist file after backing it up.

Options:
  --mirrors LIST
      Comma-separated mirrors to keep active in the Chaotic-AUR mirrorlist.
      All other Server lines are commented out.

      Accepted forms:
        cdn
        de-2
        fr-1-mirror
        se-1-mirror.chaotic.cx
        https://de-4-mirror.chaotic.cx/$repo/$arch

      Short names are expanded to *.chaotic.cx hosts. For example, de-2
      becomes de-2-mirror.chaotic.cx and cdn becomes cdn-mirror.chaotic.cx.

      Tip: if geo-mirror.chaotic.cx resolves to a blocked or broken backend,
      avoid virtual/country mirrors such as geo, random, de, or fr. Prefer
      concrete regular mirrors such as de-2, de-4, fr-1, fr-2, se-1, se-2.

  --key KEY_ID
      Add another key ID to receive and locally sign. The official current
      Chaotic-AUR bootstrap key is already included:
        3056513887B78AEB

  --keyserver URL
      Keyserver used for pacman-key --recv-key.
      Default:
        hkp://keyserver.ubuntu.com:80

      Port 80 is intentional; it often works on networks that block HKP/HKPS
      traffic on the usual keyserver ports.

  --upgrade
      Run pacman -Syyu after repair. This refreshes all package databases and
      upgrades the system.

  --no-sync
      Skip the final pacman database refresh. Useful when you only want to
      repair files/keys and run pacman yourself later.

  --noconfirm
      Pass --noconfirm to pacman package operations. This does not suppress
      sudo authentication.

  --reset
      Reset Chaotic-AUR state before reinstalling it. This deletes only the
      configured key IDs from pacman's keyring and removes only:
        /etc/pacman.d/chaotic-mirrorlist

      It does not remove /etc/pacman.d/gnupg and does not reset official Arch
      keys.

  -h, --help
      Show this help.

Use Cases:
  Fix a bad or stale Chaotic-AUR key:
    chaotic-aur-refresh

  Fix the setup without syncing package databases:
    chaotic-aur-refresh --no-sync

  Avoid geo-mirror.chaotic.cx after it routes to a blocked mirror:
    chaotic-aur-refresh --mirrors cdn,de-2,de-4,fr-1,fr-2,se-1,se-2

  Do a deeper reset when keyring/mirrorlist state looks inconsistent:
    chaotic-aur-reset --mirrors cdn,de-2,de-4,fr-1,fr-2,se-1,se-2

  Do the deeper reset and immediately upgrade:
    chaotic-aur-reset --mirrors cdn,de-2,de-4,fr-1,fr-2,se-1,se-2 --upgrade

  Use a different keyserver:
    chaotic-aur-refresh --keyserver hkps://keys.openpgp.org

What Gets Changed:
  - /etc/pacman.conf
      The live [chaotic-aur] block is replaced with a single Include line.
      This removes direct Server lines such as geo-mirror.chaotic.cx that can
      bypass your filtered mirrorlist.

  - /etc/pacman.d/chaotic-mirrorlist
      Reinstalled from chaotic-mirrorlist. If --mirrors is supplied, the chosen
      mirrors are written at the top and all original Server lines below are
      commented out for reference.

  - pacman keyring
      The Chaotic-AUR bootstrap key is received and locally signed. In reset
      mode, that configured key is deleted first and then added again.

Backups:
  Before changing files under /etc, timestamped backups are created next to the
  original files:
    /etc/pacman.conf.chaotic-aur-backup.YYYYMMDD-HHMMSS
    /etc/pacman.d/chaotic-mirrorlist.chaotic-aur-backup.YYYYMMDD-HHMMSS

Recommended Mirror Set for Northern Europe:
  The current problem shown in the terminal output is an SSL certificate
  mismatch after geo-mirror.chaotic.cx routed to a blocked Frankfurt backend.
  This is a mirror/routing problem, not primarily a PGP-key problem.

  A practical mirror filter is:
    cdn,de-2,de-4,fr-1,fr-2,se-1,se-2

  If one of those mirrors fails, edit the list and rerun the script.

Exit Behavior:
  The script stops on the first failed command. If pacman-key or pacman fails,
  read the last printed command and error; the backups remain in place.

Examples:
  chaotic-aur-refresh --mirrors cdn,de-2,de-4,fr-1,fr-2
  chaotic-aur-reset --mirrors cdn,de-2,de-4,fr-1,fr-2 --upgrade

Notes:
  This script uses sudo for system changes. Review with --help first, then run
  the command directly from your shell when you are ready.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '==> %s\n' "$*"
}

run_sudo() {
  printf '+ sudo'
  printf ' %q' "$@"
  printf '\n'
  sudo "$@"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

timestamp() {
  date '+%Y%m%d-%H%M%S'
}

backup_file() {
  local path="$1"
  [[ -e "$path" ]] || return 0

  local backup="${path}.chaotic-aur-backup.$(timestamp)"
  run_sudo cp -a "$path" "$backup"
  log "Backed up $path to $backup"
}

normalize_mirror_token() {
  local token="$1"

  token="${token,,}"
  token="${token#"${token%%[![:space:]]*}"}"
  token="${token%"${token##*[![:space:]]}"}"
  token="${token#server=}"
  token="${token#http://}"
  token="${token#https://}"
  token="${token%%/*}"
  token="${token%.chaotic.cx}"

  [[ -n "$token" ]] || return 1

  if [[ "$token" == *-mirror ]]; then
    printf '%s.chaotic.cx\n' "$token"
  else
    printf '%s-mirror.chaotic.cx\n' "$token"
  fi
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --mirrors)
        (($# >= 2)) || die "--mirrors requires a comma-separated list"
        MIRRORS="$2"
        shift 2
        ;;
      --key)
        (($# >= 2)) || die "--key requires a key ID"
        KEY_IDS+=("$2")
        shift 2
        ;;
      --keyserver)
        (($# >= 2)) || die "--keyserver requires a URL"
        KEYSERVER="$2"
        shift 2
        ;;
      --upgrade)
        SYNC_MODE="upgrade"
        shift
        ;;
      --no-sync)
        SYNC_MODE="none"
        shift
        ;;
      --noconfirm)
        PACMAN_CONFIRM_ARGS=(--noconfirm)
        shift
        ;;
      --reset)
        RESET=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

delete_chaotic_state() {
  log "Resetting Chaotic-AUR key and mirrorlist state"

  for key_id in "${KEY_IDS[@]}"; do
    if sudo pacman-key --list-keys "$key_id" >/dev/null 2>&1; then
      run_sudo pacman-key --delete "$key_id"
    else
      log "Key $key_id is not present; skipping delete"
    fi
  done

  if [[ -e "$MIRRORLIST" ]]; then
    backup_file "$MIRRORLIST"
    run_sudo rm -f "$MIRRORLIST"
  fi
}

refresh_keys() {
  log "Refreshing Chaotic-AUR pacman keys"

  run_sudo pacman-key --init
  for key_id in "${KEY_IDS[@]}"; do
    run_sudo pacman-key --recv-key "$key_id" --keyserver "$KEYSERVER"
    run_sudo pacman-key --lsign-key "$key_id"
  done
}

install_chaotic_packages() {
  log "Installing/reinstalling chaotic-keyring and chaotic-mirrorlist"
  run_sudo pacman -U "${PACMAN_CONFIRM_ARGS[@]}" "$KEYRING_URL" "$MIRRORLIST_URL"
  run_sudo pacman-key --populate archlinux chaotic
}

ensure_pacman_conf() {
  [[ -r "$PACMAN_CONF" ]] || die "cannot read $PACMAN_CONF"

  log "Normalizing [chaotic-aur] in $PACMAN_CONF"
  backup_file "$PACMAN_CONF"

  local tmp
  tmp="$(mktemp)"

  awk '
    BEGIN { in_block = 0; wrote = 0 }
    /^\[chaotic-aur\][[:space:]]*$/ {
      if (!wrote) {
        print "[chaotic-aur]"
        print "Include = /etc/pacman.d/chaotic-mirrorlist"
        wrote = 1
      }
      in_block = 1
      next
    }
    /^\[[^]]+\][[:space:]]*$/ {
      in_block = 0
    }
    !in_block {
      print
    }
    END {
      if (!wrote) {
        print ""
        print "[chaotic-aur]"
        print "Include = /etc/pacman.d/chaotic-mirrorlist"
      }
    }
  ' "$PACMAN_CONF" > "$tmp"

  run_sudo install -m 0644 "$tmp" "$PACMAN_CONF"
  rm -f "$tmp"
}

filter_mirrorlist() {
  [[ -n "$MIRRORS" ]] || return 0
  [[ -r "$MIRRORLIST" ]] || die "cannot read $MIRRORLIST"

  log "Filtering $MIRRORLIST"
  backup_file "$MIRRORLIST"

  local selected=()
  local raw token host seen
  IFS=',' read -r -a raw <<< "$MIRRORS"

  for token in "${raw[@]}"; do
    host="$(normalize_mirror_token "$token")" || die "empty mirror token in --mirrors"
    seen=0
    for existing in "${selected[@]}"; do
      if [[ "$existing" == "$host" ]]; then
        seen=1
        break
      fi
    done
    ((seen == 0)) && selected+=("$host")
  done

  ((${#selected[@]} > 0)) || die "--mirrors did not contain any usable mirrors"

  local tmp
  tmp="$(mktemp)"

  {
    printf '# Mirrorlist for Chaotic-AUR (https://aur.chaotic.cx/)\n'
    printf '# Filtered by chaotic-aur-refresh on %s.\n' "$(date -Is)"
    printf '# Active mirrors are intentionally restricted to the list below.\n\n'

    for host in "${selected[@]}"; do
      if ! grep -Fq "https://${host}/" "$MIRRORLIST"; then
        printf '# WARNING: %s was not found in the downloaded mirrorlist.\n' "$host"
      fi
      printf 'Server = https://%s/$repo/$arch\n' "$host"
    done

    printf '\n# Original downloaded mirrorlist follows with Server lines commented out.\n'
    awk '
      /^[[:space:]]*#?[[:space:]]*Server[[:space:]]*=/ {
        sub(/^[[:space:]]*#?[[:space:]]*/, "#")
        print
        next
      }
      { print }
    ' "$MIRRORLIST"
  } > "$tmp"

  run_sudo install -m 0644 "$tmp" "$MIRRORLIST"
  rm -f "$tmp"

  log "Active Chaotic-AUR mirrors:"
  for host in "${selected[@]}"; do
    printf '    https://%s/$repo/$arch\n' "$host"
  done
}

sync_databases() {
  case "$SYNC_MODE" in
    sync)
      log "Refreshing package databases"
      run_sudo pacman -Syy "${PACMAN_CONFIRM_ARGS[@]}"
      ;;
    upgrade)
      log "Refreshing package databases and upgrading the system"
      run_sudo pacman -Syyu "${PACMAN_CONFIRM_ARGS[@]}"
      ;;
    none)
      log "Skipping package database sync"
      ;;
  esac
}

main() {
  if [[ "${0##*/}" == "chaotic-aur-reset" ]]; then
    RESET=1
  fi

  parse_args "$@"

  need_cmd awk
  need_cmd date
  need_cmd grep
  need_cmd mktemp
  need_cmd pacman
  need_cmd pacman-key
  need_cmd sudo

  sudo -v

  if ((RESET == 1)); then
    delete_chaotic_state
  fi

  refresh_keys
  install_chaotic_packages
  ensure_pacman_conf
  filter_mirrorlist
  sync_databases

  log "Done"
}

main "$@"
