#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# reset-fstab-prechroot
# ---------------------------------------------------------------------------
# Pre-chroot helper:
#   1. Back up /mnt/etc/fstab by moving it to a timestamped filename.
#   2. Create a fresh /mnt/etc/fstab containing only a standard header.
#
# The old fstab is moved, not copied. Inputs are not deleted.
# ---------------------------------------------------------------------------

PROGRAM="$(basename "$0")"

ROOT="/mnt"
FSTAB=""
REVIEW=0
YES=0
VERBOSE=0

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

function usage() {
  cat <<'EOF'
reset-fstab-prechroot

Safely move an existing fstab to a timestamped backup and create a new
minimal fstab with a standard header.

Usage:
  reset-fstab-prechroot [options]

Options:
  -r, --root PATH       Mounted system root. Default: /mnt
  -f, --fstab PATH      Explicit fstab path. Overrides --root.
      --review          Show planned operation before doing anything.
  -y, --yes             Do not ask for confirmation.
  -v, --verbose         Print detailed status.
  -h, --help            Show this help.

Examples:
  sudo ./reset-fstab-prechroot --review

  sudo ./reset-fstab-prechroot --root /mnt --review

  sudo ./reset-fstab-prechroot \
    --fstab /mnt/etc/fstab \
    --review

Afterwards, append generated entries manually, for example:

  genfstab -U /mnt | sudo tee -a /mnt/etc/fstab

or inspect first:

  genfstab -U /mnt

EOF
}

# ---------------------------------------------------------------------------
# Messaging
# ---------------------------------------------------------------------------

function msg() {
  printf '%s\n' "$*"
}

function warn() {
  printf 'warning: %s\n' "$*" >&2
}

function die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

function require_arg() {
  local opt="$1"
  local val="${2:-}"

  [[ -n "$val" ]] || die "Missing argument for ${opt}."
}

function parse_args() {
  while (($# > 0)); do
    case "$1" in
      -r|--root)
        require_arg "$1" "${2:-}"
        ROOT="$2"
        shift 2
        ;;

      -f|--fstab)
        require_arg "$1" "${2:-}"
        FSTAB="$2"
        shift 2
        ;;

      --review)
        REVIEW=1
        shift
        ;;

      -y|--yes|--noconfirm|--no-confirm)
        YES=1
        shift
        ;;

      -v|--verbose)
        VERBOSE=1
        shift
        ;;

      -h|--help)
        usage
        exit 0
        ;;

      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Path logic
# ---------------------------------------------------------------------------

function resolve_paths() {
  if [[ -z "$FSTAB" ]]; then
    FSTAB="${ROOT%/}/etc/fstab"
  fi
}

function timestamp() {
  date '+%Y%m%d-%H%M%S'
}

function backup_path_for() {
  local path="$1"
  local candidate
  local n=1

  candidate="${path}.bak.$(timestamp)"

  while [[ -e "$candidate" ]]; do
    candidate="${path}.bak.$(timestamp).${n}"
    n=$((n + 1))
  done

  printf '%s\n' "$candidate"
}

# ---------------------------------------------------------------------------
# Fresh fstab content
# ---------------------------------------------------------------------------

function write_fstab_header() {
  local target="$1"

  cat > "$target" <<'EOF'
# /etc/fstab: static file system information.
#
# Use blkid(8) to print block-device UUIDs.
#
# Prefer UUID= or PARTUUID= identifiers over raw device names such as
# /dev/nvme0n1p2, because raw device names can change across boots.
#
# <file system>  <mount point>  <type>  <options>  <dump>  <pass>
EOF
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

function validate() {
  local parent

  parent="$(dirname -- "$FSTAB")"

  [[ -d "$ROOT" ]] ||
    die "Root path does not exist or is not a directory: $ROOT"

  [[ -d "$parent" ]] ||
    die "fstab parent directory does not exist: $parent"

  [[ -w "$parent" && -x "$parent" ]] ||
    die "No write/traverse permission for: $parent. Run with sudo?"

  if [[ -e "$FSTAB" && ! -f "$FSTAB" ]]; then
    die "Target exists but is not a regular file: $FSTAB"
  fi
}

# ---------------------------------------------------------------------------
# Review and confirmation
# ---------------------------------------------------------------------------

function print_plan() {
  local backup

  backup="$(backup_path_for "$FSTAB")"

  msg "Planned operation"
  msg "-----------------"
  msg "Mounted root:      $ROOT"
  msg "Target fstab:      $FSTAB"

  if [[ -f "$FSTAB" ]]; then
    msg "Existing fstab:    yes"
    msg "Backup path:       $backup"
    msg "Backup method:     mv"
  else
    msg "Existing fstab:    no"
    msg "Backup path:       not applicable"
  fi

  msg "New fstab content: standard header only"
}

function confirm_or_exit() {
  local answer

  ((YES)) && return 0

  printf 'Proceed? [y/N]: '
  read -r answer

  case "$answer" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      die "Cancelled by user."
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Main operation
# ---------------------------------------------------------------------------

function reset_fstab() {
  local parent
  local backup
  local tmp

  parent="$(dirname -- "$FSTAB")"
  tmp="$(mktemp -p "$parent" '.fstab.tmp.XXXXXX')" ||
    die "Could not create temporary file in: $parent"

  if [[ -f "$FSTAB" ]]; then
    backup="$(backup_path_for "$FSTAB")"

    ((VERBOSE)) && msg "Moving old fstab to: $backup"

    mv -- "$FSTAB" "$backup" ||
      die "Could not move old fstab to backup: $backup"
  else
    warn "No existing fstab found at: $FSTAB"
  fi

  ((VERBOSE)) && msg "Writing fresh fstab header to temporary file."

  write_fstab_header "$tmp" ||
    die "Could not write temporary fstab: $tmp"

  chmod 0644 "$tmp" ||
    die "Could not chmod temporary fstab: $tmp"

  mv -- "$tmp" "$FSTAB" ||
    die "Could not move temporary fstab into place: $FSTAB"

  msg "Fresh fstab created:"
  msg "  $FSTAB"

  if [[ -n "${backup:-}" ]]; then
    msg ""
    msg "Old fstab backup:"
    msg "  $backup"
  fi
}

function main() {
  parse_args "$@"
  resolve_paths
  validate

  if ((REVIEW || VERBOSE)); then
    print_plan
    msg ""
  fi

  confirm_or_exit
  reset_fstab
}

main "$@"
