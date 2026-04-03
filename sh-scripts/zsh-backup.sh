#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# zsh-backup
#
# Create a local 7z backup of common Zsh files and optionally transfer the
# finished archive to another machine over SSH.
#
# Defaults:
#   - encryption: enabled
#   - header encryption: enabled when encryption is enabled
#   - transfer: disabled
#   - transfer method: scp
#   - local output directory: $HOME/compressed-files
#   - remote output directory: compressed-files (relative to remote $HOME)
#
# Notes:
#   - --no-encryption disables both password protection and header encryption.
#   - .zsh_profile is included recursively if it exists and is a directory.
#   - If an exact output archive path already exists, the script enumerates
#     the filename rather than overwriting it.
# -----------------------------------------------------------------------------

readonly SCRIPT_NAME="$(basename "$0")"

use_ssh=0
method='scp'
method_explicit=0
encrypt=1
verbose=0
verify=0
delete_local_after_transfer=0

ip_address=''
recipient=''
remote_dir='compressed-files'
output_target="$HOME/compressed-files"
archive_path=''

declare -a sources=()
declare -a skipped_sources=()

function pick_help_pager() {
  if [[ -n "${HELP_PAGER:-}" ]]; then
    printf '%s\n' "$HELP_PAGER"
    return 0
  fi

  if command -v less >/dev/null 2>&1; then
    printf '%s\n' 'less -R'
  else
    printf '%s\n' 'cat'
  fi
}

function show_help() {
  local pager_cmd
  pager_cmd="$(pick_help_pager)"

  cat <<EOF | eval "$pager_cmd"
Usage:
  ${SCRIPT_NAME} [OPTIONS]

Description:
  Create a backup archive containing:
    - ~/.zshrc
    - ~/.zsh_history
    - ~/.zprofile
    - ~/.zsh_profile

  If ~/.zsh_profile is a directory, it is included recursively.

Options:
  -s, --ssh
      Also transfer the finished archive to another machine over SSH.

  -m, --method METHOD
      Transfer method when --ssh is enabled.
      Allowed: scp, rsync
      Default: scp

  -i, --ip-address HOST
      Remote IP address or host name, e.g. 192.168.1.69

  -r, --recipient, --recipient-username USER
      Remote SSH username, e.g. heini

  -o, --output PATH
      Local output target.
      If PATH ends in .7z, it is treated as the desired archive path.
      Otherwise, PATH is treated as an output directory and a timestamped
      archive is created inside it.
      Default: \$HOME/compressed-files

  --remote-dir DIR
      Destination directory on the remote machine.
      This is interpreted relative to the remote user's home directory unless
      you pass an absolute path.
      Default: compressed-files

  --verify
      After transfer, compare local and remote SHA256 sums.

  --delete-local-after-transfer
      Delete the local archive after a successful transfer.
      If --verify is used, deletion only happens after the checksum matches.

  --no-encryption
      Disable password protection.
      This also disables hidden header encryption.

  -v, --verbose
      Increase verbosity. Can be supplied multiple times.

  -h, --help
      Show this help text and exit.

Dependency rules:
  - 7z is always required.
  - sha256sum is required only when --verify is used.
  - If --ssh and --method scp are used, ssh + scp are required.
  - If --ssh and --method rsync are used, ssh + rsync are required.

Examples:
  ${SCRIPT_NAME}

  ${SCRIPT_NAME} -o "\$HOME/backups/zsh"

  ${SCRIPT_NAME} -o "\$HOME/backups/zsh/manual.7z"

  ${SCRIPT_NAME} --no-encryption

  ${SCRIPT_NAME} -s -i 192.168.1.69 -r heini -m scp

  ${SCRIPT_NAME} -s -i 192.168.1.69 -r heini -m rsync -v

  ${SCRIPT_NAME} -s -i 192.168.1.69 -r heini \\
    --remote-dir "/home/heini/other-backups"

  ${SCRIPT_NAME} -s --verify --delete-local-after-transfer
EOF
}

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function log() {
  printf '%s\n' "$*"
}

function vlog() {
  if (( verbose > 0 )); then
    printf '%s\n' "$*"
  fi
}

function have_command() {
  command -v "$1" >/dev/null 2>&1
}

function expand_path() {
  local path="$1"

  case "$path" in
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
      printf '%s\n' "$HOME/${path#~/}"
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}

function normalize_method() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

function parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--ssh)
        use_ssh=1
        shift
        ;;

      -m|--method)
        [[ $# -ge 2 ]] || die "Option '$1' requires a value."
        method="$(normalize_method "$2")"
        method_explicit=1
        shift 2
        ;;

      -i|--ip-address|--ip-adress)
        [[ $# -ge 2 ]] || die "Option '$1' requires a value."
        ip_address="$2"
        shift 2
        ;;

      -r|--recipient|--recipient-username)
        [[ $# -ge 2 ]] || die "Option '$1' requires a value."
        recipient="$2"
        shift 2
        ;;

      -o|--output)
        [[ $# -ge 2 ]] || die "Option '$1' requires a value."
        output_target="$2"
        shift 2
        ;;

      --remote-dir)
        [[ $# -ge 2 ]] || die "Option '$1' requires a value."
        remote_dir="$2"
        shift 2
        ;;

      --verify)
        verify=1
        shift
        ;;

      --delete-local-after-transfer)
        delete_local_after_transfer=1
        shift
        ;;

      --no-encryption)
        encrypt=0
        shift
        ;;

      -v|--verbose)
        verbose=$(( verbose + 1 ))
        shift
        ;;

      -h|--help)
        show_help
        exit 0
        ;;

      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

function validate_args() {
  case "$method" in
    scp|rsync)
      ;;
    *)
      die "Invalid method '$method'. Allowed values: scp, rsync."
      ;;
  esac

  if (( ! use_ssh )); then
    (( method_explicit == 0 )) || die '--method requires --ssh.'
    [[ -z "$ip_address" ]] || die '--ip-address requires --ssh.'
    [[ -z "$recipient" ]] || die '--recipient requires --ssh.'
    [[ -z "$remote_dir" ]] || die '--remote-dir requires --ssh.'
    (( verify == 0 )) || die '--verify requires --ssh.'
    (( delete_local_after_transfer == 0 )) || \
      die '--delete-local-after-transfer requires --ssh.'
  fi
}

function prompt_for_ssh_details() {
  (( use_ssh )) || return 0

  if [[ -z "$recipient" ]]; then
    read -rp 'Remote SSH username: ' recipient
  fi

  if [[ -z "$ip_address" ]]; then
    read -rp 'Remote IP address or host: ' ip_address
  fi

  [[ -n "$recipient" ]] || die 'Remote SSH username cannot be empty.'
  [[ -n "$ip_address" ]] || die 'Remote IP address or host cannot be empty.'
}

function check_dependencies() {
  local missing=0
  local -a lines=()

  if ! have_command 7z; then
    lines+=('  - Missing command: 7z        (install package: 7zip)')
    missing=1
  fi

  if (( verify )) && ! have_command sha256sum; then
    lines+=(
      '  - Missing command: sha256sum (install package: coreutils)'
    )
    missing=1
  fi

  if (( use_ssh )); then
    if ! have_command ssh; then
      lines+=('  - Missing command: ssh       (install package: openssh)')
      missing=1
    fi

    case "$method" in
      scp)
        if ! have_command scp; then
          lines+=(
            '  - Missing command: scp       (install package: openssh)'
          )
          missing=1
        fi
        ;;
      rsync)
        if ! have_command rsync; then
          lines+=(
            '  - Missing command: rsync     (install package: rsync)'
          )
          missing=1
        fi
        ;;
    esac
  fi

  if (( missing )); then
    printf 'Required command(s) are missing:\n' >&2
    printf '%s\n' "${lines[@]}" >&2
    exit 1
  fi
}

function collect_sources() {
  local item

  sources=()
  skipped_sources=()

  for item in .zshrc .zsh_history .zprofile .zsh_profile; do
    if [[ -e "$HOME/$item" ]]; then
      sources+=("$item")
    else
      skipped_sources+=("$item")
    fi
  done

  (( ${#sources[@]} > 0 )) || \
    die 'No Zsh files/directories were found to back up.'
}

function print_source_summary() {
  local item

  (( verbose > 0 )) || return 0

  log 'Sources selected for backup:'
  for item in "${sources[@]}"; do
    if [[ -d "$HOME/$item" ]]; then
      printf '  - %s/ (directory; included recursively)\n' "$item"
    else
      printf '  - %s\n' "$item"
    fi
  done

  if (( ${#skipped_sources[@]} > 0 )); then
    log 'Sources not found and therefore skipped:'
    for item in "${skipped_sources[@]}"; do
      printf '  - %s\n' "$item"
    done
  fi
}

function next_available_path() {
  local requested="$1"
  local dir base stem ext candidate index

  dir="$(dirname -- "$requested")"
  base="$(basename -- "$requested")"

  if [[ "$base" == *.* ]]; then
    stem="${base%.*}"
    ext=".${base##*.}"
  else
    stem="$base"
    ext=''
  fi

  candidate="$requested"
  index=1

  while [[ -e "$candidate" ]]; do
    candidate="${dir}/${stem}-${index}${ext}"
    index=$(( index + 1 ))
  done

  printf '%s\n' "$candidate"
}

function prepare_output_path() {
  output_target="$(expand_path "$output_target")"

  if [[ "$output_target" == *.7z ]]; then
    mkdir -p -- "$(dirname -- "$output_target")"
    archive_path="$(next_available_path "$output_target")"
  else
    mkdir -p -- "$output_target"
    archive_path="$output_target/zsh-backup-$(date +%F_%H%M%S).7z"
    archive_path="$(next_available_path "$archive_path")"
  fi

  vlog "Local archive path: $archive_path"
}

function create_archive() {
  if (( encrypt )); then
    log 'Creating encrypted 7z archive.'
    log 'A password prompt from 7z will appear now.'
  else
    log 'Creating unencrypted 7z archive.'
    vlog 'Header encryption is disabled because --no-encryption was used.'
  fi

  (
    cd "$HOME" || exit 1

    if (( encrypt )); then
      7z a -t7z -mx=9 -mhe=on -p \
        "$archive_path" \
        "${sources[@]}"
    else
      7z a -t7z -mx=9 \
        "$archive_path" \
        "${sources[@]}"
    fi
  )
}

function remote_archive_path() {
  local archive_base
  archive_base="$(basename -- "$archive_path")"
  printf '%s/%s\n' "${remote_dir%/}" "$archive_base"
}

function transfer_archive() {
  local remote_host
  remote_host="${recipient}@${ip_address}"

  (( use_ssh )) || return 0

  vlog "Ensuring remote directory exists: ${remote_host}:${remote_dir}/"
  ssh -- "$remote_host" "mkdir -p -- '$remote_dir'"

  case "$method" in
    scp)
      log "Transferring archive with scp to ${remote_host}:${remote_dir}/"
      scp -p -- "$archive_path" "${remote_host}:${remote_dir}/"
      ;;
    rsync)
      log "Transferring archive with rsync to ${remote_host}:${remote_dir}/"
      rsync -avh \
        --partial \
        --human-readable \
        --info=progress2,stats2 \
        -e ssh \
        -- "$archive_path" "${remote_host}:${remote_dir}/"
      ;;
  esac
}

function verify_transfer() {
  local remote_host remote_path local_sum remote_sum

  (( verify )) || return 0

  remote_host="${recipient}@${ip_address}"
  remote_path="$(remote_archive_path)"

  log 'Verifying local and remote SHA256 checksums.'

  local_sum="$(sha256sum -- "$archive_path" | awk '{print $1}')"
  remote_sum="$(
    ssh -- "$remote_host" \
      "sha256sum -- '$remote_path' | awk '{print \$1}'"
  )"

  printf 'Local  SHA256: %s\n' "$local_sum"
  printf 'Remote SHA256: %s\n' "$remote_sum"

  [[ "$local_sum" == "$remote_sum" ]] || die 'Checksum mismatch.'
}

function maybe_delete_local_archive() {
  (( delete_local_after_transfer )) || return 0
  (( use_ssh )) || return 0

  rm -f -- "$archive_path"
  log "Deleted local archive: $archive_path"
}

function print_summary() {
  local archive_base
  archive_base="$(basename -- "$archive_path")"

  printf 'Created locally: %s\n' "$archive_path"

  if (( use_ssh )); then
    printf 'Copied remotely: %s@%s:%s/%s\n' \
      "$recipient" \
      "$ip_address" \
      "${remote_dir%/}" \
      "$archive_base"
  fi
}

function main() {
  parse_args "$@"
  validate_args
  prompt_for_ssh_details
  check_dependencies
  collect_sources
  print_source_summary
  prepare_output_path
  create_archive
  transfer_archive
  verify_transfer
  print_summary
  maybe_delete_local_archive
}

main "$@"
