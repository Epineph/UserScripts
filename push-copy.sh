#!/usr/bin/env bash

set -euo pipefail

function show_help() {
  cat <<'EOF'
Usage:
  push-copy.sh [options] SRC... DEST_PATH

Description:
  Copy one or more local sources to a remote host over SSH using either rsync
  or scp.

  Default remote target:
    heini@192.168.1.69

Modes:
  rsync   Incremental sync with progress and optional dry-run (default)
  scp     Simple SSH/SFTP-based copy with standard scp progress meter

Options:
  -m, --mode MODE         Transfer mode: rsync | scp
  -H, --host HOST         Remote host or IP
  -u, --user USER         Remote username
  -p, --port PORT         SSH port
  -i, --identity FILE     SSH private key
  -c, --compress          Enable compression
  -n, --dry-run           Dry-run (rsync mode only)
  -d, --delete            Delete remote extras (rsync mode only)
  -r, --recursive         Recursive copy in scp mode
  -V, --debug-ssh         Enable scp debug output (-v)
  -h, --help              Show this help

Notes:
  1. In rsync mode, a trailing slash matters:
       /src/  -> copy contents of src
       /src   -> copy src directory itself

  2. In scp mode, recursive directory copy requires --recursive.

  3. Compression differs by mode:
       rsync --compress   -> rsync-negotiated stream compression
       scp   --compress   -> ssh -C stream compression

Examples:
  push-copy.sh ~/file.txt /home/heini/inbox/

  push-copy.sh --mode scp ~/file.txt /home/heini/inbox/

  push-copy.sh --mode rsync --dry-run ~/Documents/ /home/heini/Documents/

  push-copy.sh --mode rsync --delete ~/project/ /home/heini/project/

  push-copy.sh --mode scp --recursive ~/Pictures \
    /home/heini/backups/

  push-copy.sh --compress ~/data/ /home/heini/data/

  push-copy.sh --mode scp --compress ~/bigfile.iso \
    /home/heini/incoming/
EOF
}

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

function quote_for_display() {
  printf '%q' "$1"
}

function run_rsync() {
  local host="$1"
  local user="$2"
  local port="$3"
  local identity="$4"
  local compress="$5"
  local dry_run="$6"
  local delete_mode="$7"
  shift 7

  local dest_path="${!#}"
  local -a srcs=("${@:1:$(($# - 1))}")

  local -a ssh_cmd=(ssh)
  [[ -n "$port" ]] && ssh_cmd+=(-p "$port")
  [[ -n "$identity" ]] && ssh_cmd+=(-i "$identity")

  local remote="${user}@${host}:${dest_path}"

  local -a cmd=(
    rsync
    -a
    -h
    -v
    --info=progress2,stats2
    --partial
    --itemize-changes
    -e
    "$(printf '%q ' "${ssh_cmd[@]}")"
  )

  ((compress)) && cmd+=(-z)
  ((dry_run)) && cmd+=(-n)
  ((delete_mode)) && cmd+=(--delete)

  printf '\nMode          : rsync\n'
  printf 'Remote target : %s\n' "$remote"
  printf 'Compress      : %s\n' "$compress"
  printf 'Dry run       : %s\n' "$dry_run"
  printf 'Delete        : %s\n' "$delete_mode"
  printf 'Sources       :\n'
  local src
  for src in "${srcs[@]}"; do
    printf '  - %s\n' "$src"
  done

  printf '\nCommand:\n  '
  local part
  for part in "${cmd[@]}" "${srcs[@]}" "$remote"; do
    quote_for_display "$part"
    printf ' '
  done
  printf '\n\n'

  "${cmd[@]}" "${srcs[@]}" "$remote"
}

function run_scp() {
  local host="$1"
  local user="$2"
  local port="$3"
  local identity="$4"
  local compress="$5"
  local recursive="$6"
  local debug_ssh="$7"
  shift 7

  local dest_path="${!#}"
  local -a srcs=("${@:1:$(($# - 1))}")

  local remote="${user}@${host}:${dest_path}"

  local -a cmd=(scp)
  [[ -n "$port" ]] && cmd+=(-P "$port")
  [[ -n "$identity" ]] && cmd+=(-i "$identity")
  ((compress)) && cmd+=(-C)
  ((recursive)) && cmd+=(-r)
  ((debug_ssh)) && cmd+=(-v)

  printf '\nMode          : scp\n'
  printf 'Remote target : %s\n' "$remote"
  printf 'Compress      : %s\n' "$compress"
  printf 'Recursive     : %s\n' "$recursive"
  printf 'Debug SSH     : %s\n' "$debug_ssh"
  printf 'Sources       :\n'
  local src
  for src in "${srcs[@]}"; do
    printf '  - %s\n' "$src"
  done

  printf '\nCommand:\n  '
  local part
  for part in "${cmd[@]}" "${srcs[@]}" "$remote"; do
    quote_for_display "$part"
    printf ' '
  done
  printf '\n\n'

  "${cmd[@]}" "${srcs[@]}" "$remote"
}

function main() {
  require_cmd ssh

  local mode="rsync"
  local host="192.168.1.69"
  local user="heini"
  local port=""
  local identity=""
  local compress=0
  local dry_run=0
  local delete_mode=0
  local recursive=0
  local debug_ssh=0

  local -a positionals=()

  while (($# > 0)); do
    case "$1" in
      -m|--mode)
        (($# >= 2)) || die "Missing value for $1"
        mode="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
        shift 2
        ;;
      -H|--host)
        (($# >= 2)) || die "Missing value for $1"
        host="$2"
        shift 2
        ;;
      -u|--user)
        (($# >= 2)) || die "Missing value for $1"
        user="$2"
        shift 2
        ;;
      -p|--port)
        (($# >= 2)) || die "Missing value for $1"
        port="$2"
        shift 2
        ;;
      -i|--identity)
        (($# >= 2)) || die "Missing value for $1"
        identity="$2"
        shift 2
        ;;
      -c|--compress)
        compress=1
        shift
        ;;
      -n|--dry-run)
        dry_run=1
        shift
        ;;
      -d|--delete)
        delete_mode=1
        shift
        ;;
      -r|--recursive)
        recursive=1
        shift
        ;;
      -V|--debug-ssh)
        debug_ssh=1
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      --)
        shift
        while (($# > 0)); do
          positionals+=("$1")
          shift
        done
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        positionals+=("$1")
        shift
        ;;
    esac
  done

  [[ "$mode" == "rsync" || "$mode" == "scp" ]] || \
    die "Mode must be rsync or scp"

  ((${#positionals[@]} >= 2)) || \
    die "Need at least one source and one destination path"

  local dest_path="${positionals[-1]}"
  local -a srcs=("${positionals[@]:0:${#positionals[@]}-1}")

  [[ -n "$dest_path" ]] || die "Destination path is empty"

  local src
  for src in "${srcs[@]}"; do
    [[ -e "$src" ]] || die "Source does not exist: $src"
  done

  if [[ "$mode" == "rsync" ]]; then
    require_cmd rsync
    run_rsync \
      "$host" "$user" "$port" "$identity" "$compress" "$dry_run" \
      "$delete_mode" "${srcs[@]}" "$dest_path"
    return
  fi

  require_cmd scp

  ((dry_run == 0)) || die "--dry-run is only supported in rsync mode"
  ((delete_mode == 0)) || die "--delete is only supported in rsync mode"

  if ((recursive == 0)); then
    for src in "${srcs[@]}"; do
      [[ -d "$src" ]] && die \
        "Directory source in scp mode requires --recursive: $src"
    done
  fi

  run_scp \
    "$host" "$user" "$port" "$identity" "$compress" "$recursive" \
    "$debug_ssh" "${srcs[@]}" "$dest_path"
}

main "$@"