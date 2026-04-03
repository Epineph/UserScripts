#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# rsend — Robust rsync sender: file/dir to remote via SSH, with progress
# ──────────────────────────────────────────────────────────────────────────────
set -Euo pipefail

# Globals (defaults)
PORT=22
USER_DEFAULT="$(id -un)"
USER_REMOTE="$USER_DEFAULT"
HOST_REMOTE=""
DEST_REMOTE=""
SRC_PATH=""
RECURSIVE=0
DRYRUN=0
COMPRESS=0
MKPATH=0
SSH_KEY=""

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────
function die() {
  echo "Error: $*" >&2
  exit 1
}

function have() {
  command -v "$1" >/dev/null 2>&1
}

function help_pager() {
  if [[ -n "${HELP_PAGER:-}" ]]; then
    eval "$HELP_PAGER"
  elif have less; then
    less -R
  else
    cat
  fi
}

function show_help() {
  cat <<'HLP' | help_pager
# rsend — rsync file/dir to remote over SSH (with progress)

## Synopsis
  rsend --source <path> --host <ip-or-host> --dest <remote-dir> [options]

## Required
  --source, -s   Local path (file or directory) to send.
  --host,   -H   Remote host/IP (e.g., 192.168.1.71).
  --dest,   -d   Remote destination directory (created with --mkpath).

## Directory safety
  When --source is a directory, you **must** pass --recursive to proceed.

## Common options
  --user,    -u  Remote username (default: current user).
  --port,    -p  SSH port (default: 22).
  --key,     -k  SSH private key path (e.g., ~/.ssh/id_ed25519).
  --compress -z  Enable rsync compression (-z) — useful for WAN links.
  --dry-run  -n  Show what would happen without sending data.
  --mkpath       Create destination directory on the remote before transfer.
  --delete       Mirror: delete remote files not present locally (use with care).
  --bwlimit MB   Bandwidth limit in MB/s (e.g., --bwlimit 50).

## Examples
  # Example: your Windows 11 ISO to /home/heini/Documents on 192.168.1.71
  rsend -s "$HOME/Downloads/26200.6584.250915-1905.25h2_ge_release_CLIENT.iso" \
        -u heini -H 192.168.1.71 -d /home/heini/Documents

  # Directory transfer (requires --recursive)
  rsend -s "$HOME/data/projectA" -u heini -H 192.168.1.71 -d /srv/archive \
        --recursive --mkpath

  # SSH key and non-default port, with compression
  rsend -s "./bigfile.bin" -u heini -H 192.168.1.71 -d /home/heini/inbox \
        -p 2222 -k ~/.ssh/id_ed25519 --compress

## Notes
  - Shows progress and keeps partial files (-P).
  - Uses archive mode (-a) to preserve timestamps/permissions/etc.
  - For directories, --recursive is a deliberate safety gate.
  - Set HELP_PAGER to customize help paging (e.g., "less -R", "cat").

## Exit codes
  0 success, non-zero on error.

HLP
}

# ──────────────────────────────────────────────────────────────────────────────
# Arg parsing
# ──────────────────────────────────────────────────────────────────────────────
function parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --help | -h)
      show_help
      exit 0
      ;;
    --source | -s)
      SRC_PATH="${2:-}"
      shift
      ;;
    --host | -H)
      HOST_REMOTE="${2:-}"
      shift
      ;;
    --dest | -d)
      DEST_REMOTE="${2:-}"
      shift
      ;;
    --user | -u)
      USER_REMOTE="${2:-}"
      shift
      ;;
    --port | -p)
      PORT="${2:-}"
      shift
      ;;
    --key | -k)
      SSH_KEY="${2:-}"
      shift
      ;;
    --recursive) RECURSIVE=1 ;;
    --dry-run | -n) DRYRUN=1 ;;
    --compress | -z) COMPRESS=1 ;;
    --mkpath) MKPATH=1 ;;
    --delete) DELETE_FLAG="--delete" ;;
    --bwlimit)
      BWLIMIT_MB="${2:-}"
      shift
      ;;
    --)
      shift
      break
      ;;
    *) die "Unknown option: $1" ;;
    esac
    shift || true
  done

  [[ -n "$SRC_PATH" ]] || die "--source is required"
  [[ -n "$HOST_REMOTE" ]] || die "--host is required"
  [[ -n "$DEST_REMOTE" ]] || die "--dest is required"
}

# ──────────────────────────────────────────────────────────────────────────────
# Pre-flight checks
# ──────────────────────────────────────────────────────────────────────────────
function preflight() {
  have rsync || die "rsync not found"
  have ssh || die "ssh not found"

  [[ -e "$SRC_PATH" ]] || die "Source does not exist: $SRC_PATH"

  if [[ -d "$SRC_PATH" && "$RECURSIVE" -ne 1 ]]; then
    die "Source is a directory; pass --recursive to proceed."
  fi

  # Normalize remote destination to end with a '/'
  case "$DEST_REMOTE" in
  */) : ;;
  *) DEST_REMOTE="${DEST_REMOTE}/" ;;
  esac

  # Optional: create remote directory
  if [[ "$MKPATH" -eq 1 ]]; then
    local ssh_cmd=(ssh -p "$PORT")
    [[ -n "$SSH_KEY" ]] && ssh_cmd+=(-i "$SSH_KEY")
    "${ssh_cmd[@]}" "${USER_REMOTE}@${HOST_REMOTE}" \
      "mkdir -p -- '$(printf %q "$DEST_REMOTE")'" ||
      die "Failed to create remote dir: $DEST_REMOTE"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Build and run rsync
# ──────────────────────────────────────────────────────────────────────────────
function run_rsync() {
  local rsync_opts=(-a -v -P)
  local ssh_cmd=(ssh -p "$PORT")
  [[ -n "$SSH_KEY" ]] && ssh_cmd+=(-i "$SSH_KEY")

  [[ "$DRYRUN" -eq 1 ]] && rsync_opts+=(--dry-run)
  [[ "$COMPRESS" -eq 1 ]] && rsync_opts+=(-z)
  [[ -n "${DELETE_FLAG:-}" ]] && rsync_opts+=("$DELETE_FLAG")

  if [[ -n "${BWLIMIT_MB:-}" ]]; then
    # rsync expects KB/s; convert MB/s → KB/s (MiB to KiB to be conservative).
    # 1 MiB/s = 1024 KiB/s
    if [[ "$BWLIMIT_MB" =~ ^[0-9]+$ ]]; then
      local kib=$((BWLIMIT_MB * 1024))
      rsync_opts+=(--bwlimit="$kib")
    else
      die "--bwlimit expects an integer MB/s value"
    fi
  fi

  local src="$SRC_PATH"
  local dst="${USER_REMOTE}@${HOST_REMOTE}:${DEST_REMOTE}"

  rsync "${rsync_opts[@]}" -e "$(printf '%q ' "${ssh_cmd[@]}")" \
    -- "$src" "$dst"
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
function main() {
  parse_args "$@"
  preflight
  run_rsync
}

main "$@"
