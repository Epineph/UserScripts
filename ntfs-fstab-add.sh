#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# ntfs-fstab-add
#
# Add or update an NTFS mount in /etc/fstab using the partition UUID.
#
# Designed for cases such as:
#   /dev/nvme0n1p5  ->  /extra
#
# Default behavior:
#   - validate source device and filesystem
#   - prompt to create missing mountpoint
#   - back up /etc/fstab
#   - add or replace the relevant fstab entry
#   - verify the resulting fstab syntax
#   - mount only the new target immediately
#
# Notes:
#   - Uses the current invoking user's UID/GID for NTFS ownership.
#   - If run via sudo, SUDO_UID/SUDO_GID are honored.
#   - If you prefer "mount -a" semantics, use --mount-all.
# -----------------------------------------------------------------------------

set -o errexit
set -o nounset
set -o pipefail

PROGNAME="${0##*/}"
FSTAB_PATH="/etc/fstab"
FS_TYPE_DEFAULT="ntfs"
MOUNT_MODE="target"
FORCE_CREATE="false"
QUIET="false"

PARTITION=""
MOUNTPOINT_DIR=""
FS_TYPE="$FS_TYPE_DEFAULT"

# These options mirror your existing /shared entry closely.
MOUNT_OPTIONS="rw,relatime,uid=%UID%,gid=%GID%,dmask=0022,fmask=0022,\
iocharset=utf8"

# -----------------------------------------------------------------------------
# Messaging
# -----------------------------------------------------------------------------

function info() {
  [[ "$QUIET" == "true" ]] && return 0
  printf '[INFO] %s\n' "$*"
}

function warn() {
  printf '[WARN] %s\n' "$*" >&2
}

function die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

function show_help() {
  cat <<'EOF'
Usage:
  ntfs-fstab-add [options] <partition> <mountpoint>
  ntfs-fstab-add [options] -p <partition> -m <mountpoint>

Description:
  Add or update an NTFS mount entry in /etc/fstab using the partition UUID.

Arguments:
  <partition>     Block device, e.g. /dev/nvme0n1p5
  <mountpoint>    Absolute mount path, e.g. /extra

Options:
  -p, --partition PATH     Source block device
  -m, --mountpoint PATH    Target mount directory
      --fs-type TYPE       Filesystem type to write in fstab
                           Default: ntfs
      --options OPTS       Mount options to write in fstab
                           Tokens %UID% and %GID% are expanded
      --mount-now          Mount only the new target immediately
                           This is the default behavior
      --mount-all          Run "sudo mount -a" after updating fstab
      --no-mount-now       Do not mount immediately
  -f, --force-create       Create missing mountpoint without prompting
  -q, --quiet              Less output
  -h, --help               Show this help

Examples:
  ntfs-fstab-add /dev/nvme0n1p5 /extra

  ntfs-fstab-add -p /dev/nvme0n1p5 -m /extra

  ntfs-fstab-add /dev/nvme0n1p5 /extra --no-mount-now

  ntfs-fstab-add /dev/nvme0n1p5 /extra --mount-all

  ntfs-fstab-add /dev/nvme0n1p5 /extra \
    --fs-type ntfs3

  ntfs-fstab-add /dev/nvme0n1p5 /extra \
    --options 'rw,relatime,uid=%UID%,gid=%GID%,dmask=0022,fmask=0022,\
iocharset=utf8,windows_names'

Notes:
  - The script backs up /etc/fstab before changing it.
  - Active entries matching the same UUID or mountpoint are replaced.
  - If Windows hibernation / Fast Startup was used, NTFS mounting may fail
    until Windows fully shuts the volume down.
EOF
}

# -----------------------------------------------------------------------------
# Prompts and checks
# -----------------------------------------------------------------------------

function prompt_yes_no() {
  local prompt="$1"
  local reply

  while true; do
    read -r -p "$prompt [y/N]: " reply
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no|"") return 1 ;;
      *)
        warn "Please answer yes or no."
        ;;
    esac
  done
}

function require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
}

function require_sudo() {
  sudo -v || die "sudo authentication failed."
}

# -----------------------------------------------------------------------------
# UID/GID helpers
# -----------------------------------------------------------------------------

function effective_uid() {
  if [[ -n "${SUDO_UID:-}" ]]; then
    printf '%s\n' "$SUDO_UID"
  else
    id -u
  fi
}

function effective_gid() {
  if [[ -n "${SUDO_GID:-}" ]]; then
    printf '%s\n' "$SUDO_GID"
  else
    id -g
  fi
}

# -----------------------------------------------------------------------------
# Validation helpers
# -----------------------------------------------------------------------------

function normalize_mountpoint() {
  local path="$1"

  [[ "$path" == /* ]] || die "Mountpoint must be an absolute path: $path"
  [[ "$path" != *[[:space:]]* ]] || die "Whitespace in mountpoint is not supported."

  if [[ "$path" != "/" ]]; then
    path="${path%/}"
  fi

  printf '%s\n' "$path"
}

function validate_partition() {
  local dev="$1"

  [[ -b "$dev" ]] || die "Not a block device: $dev"
}

function detect_fstype() {
  local dev="$1"
  local fstype

  fstype="$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
  [[ -n "$fstype" ]] || die "Could not determine filesystem type for: $dev"

  printf '%s\n' "$fstype"
}

function get_uuid() {
  local dev="$1"
  local uuid

  uuid="$(blkid -o value -s UUID "$dev" 2>/dev/null || true)"
  [[ -n "$uuid" ]] || die "Could not determine UUID for: $dev"

  printf '%s\n' "$uuid"
}

function ensure_mountpoint() {
  local dir="$1"

  if [[ -d "$dir" ]]; then
    return 0
  fi

  if [[ "$FORCE_CREATE" == "true" ]]; then
    info "Creating mountpoint: $dir"
    sudo mkdir -p -- "$dir"
    return 0
  fi

  if prompt_yes_no "Mountpoint does not exist: $dir. Create it?"; then
    sudo mkdir -p -- "$dir"
  else
    die "Mountpoint does not exist and was not created."
  fi
}

function verify_mountpoint_not_busy() {
  local dir="$1"

  if findmnt --target "$dir" >/dev/null 2>&1; then
    local src
    src="$(findmnt -no SOURCE --target "$dir" 2>/dev/null || true)"
    die "Mountpoint is already in use: $dir${src:+ (currently: $src)}"
  fi
}

# -----------------------------------------------------------------------------
# fstab update
# -----------------------------------------------------------------------------

function build_mount_options() {
  local uid gid opts

  uid="$(effective_uid)"
  gid="$(effective_gid)"

  opts="${MOUNT_OPTIONS//%UID%/$uid}"
  opts="${opts//%GID%/$gid}"

  printf '%s\n' "$opts"
}

function build_fstab_entry() {
  local uuid="$1"
  local mount_dir="$2"
  local opts="$3"

  printf 'UUID=%s %s %s %s 0 0\n' \
    "$uuid" "$mount_dir" "$FS_TYPE" "$opts"
}

function backup_fstab() {
  local stamp backup

  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="/etc/fstab.bak.${stamp}"

  sudo cp -a -- "$FSTAB_PATH" "$backup"
  info "Backup created: $backup"
}

function write_updated_fstab() {
  local uuid="$1"
  local mount_dir="$2"
  local entry="$3"
  local tmp

  tmp="$(mktemp)"

  awk \
    -v uuid="$uuid" \
    -v mount_dir="$mount_dir" \
    -v entry="$entry" '
      BEGIN {
        replaced = 0
      }

      /^[[:space:]]*#/ || /^[[:space:]]*$/ {
        print
        next
      }

      $1 == "UUID=" uuid || $2 == mount_dir {
        if (replaced == 0) {
          print entry
          replaced = 1
        }
        next
      }

      {
        print
      }

      END {
        if (replaced == 0) {
          print ""
          print entry
        }
      }
    ' "$FSTAB_PATH" > "$tmp"

  findmnt --verify --tab-file "$tmp" >/dev/null 2>&1 || {
    rm -f -- "$tmp"
    die "Generated fstab failed verification. No changes were written."
  }

  sudo install -m 0644 -- "$tmp" "$FSTAB_PATH"
  rm -f -- "$tmp"
}

# -----------------------------------------------------------------------------
# Mounting
# -----------------------------------------------------------------------------

function mount_now() {
  local mount_dir="$1"

  case "$MOUNT_MODE" in
    none)
      info "Skipping immediate mount."
      ;;
    target)
      info "Mounting target via fstab: $mount_dir"
      sudo mount -- "$mount_dir"
      ;;
    all)
      info 'Running: sudo mount -a'
      sudo mount -a
      ;;
    *)
      die "Internal error: unsupported mount mode: $MOUNT_MODE"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

function parse_args() {
  while (($# > 0)); do
    case "$1" in
      -p|--partition)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        PARTITION="$2"
        shift 2
        ;;
      -m|--mountpoint)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        MOUNTPOINT_DIR="$2"
        shift 2
        ;;
      --fs-type)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        FS_TYPE="$2"
        shift 2
        ;;
      --options)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        MOUNT_OPTIONS="$2"
        shift 2
        ;;
      --mount-now)
        MOUNT_MODE="target"
        shift
        ;;
      --mount-all)
        MOUNT_MODE="all"
        shift
        ;;
      --no-mount-now)
        MOUNT_MODE="none"
        shift
        ;;
      -f|--force-create)
        FORCE_CREATE="true"
        shift
        ;;
      -q|--quiet)
        QUIET="true"
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        if [[ -z "$PARTITION" ]]; then
          PARTITION="$1"
        elif [[ -z "$MOUNTPOINT_DIR" ]]; then
          MOUNTPOINT_DIR="$1"
        else
          die "Unexpected extra argument: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$PARTITION" ]] || die "Partition is required."
  [[ -n "$MOUNTPOINT_DIR" ]] || die "Mountpoint is required."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

function main() {
  local actual_fstype uuid opts entry

  require_command awk
  require_command blkid
  require_command findmnt
  require_command install
  require_command lsblk
  require_command mount
  require_command sudo

  parse_args "$@"
  require_sudo

  PARTITION="$(readlink -f -- "$PARTITION")"
  MOUNTPOINT_DIR="$(normalize_mountpoint "$MOUNTPOINT_DIR")"

  validate_partition "$PARTITION"

  actual_fstype="$(detect_fstype "$PARTITION")"
  [[ "${actual_fstype,,}" == "ntfs" ]] || {
    die "Filesystem on $PARTITION is '$actual_fstype', not 'ntfs'."
  }

  ensure_mountpoint "$MOUNTPOINT_DIR"
  verify_mountpoint_not_busy "$MOUNTPOINT_DIR"

  uuid="$(get_uuid "$PARTITION")"
  opts="$(build_mount_options)"
  entry="$(build_fstab_entry "$uuid" "$MOUNTPOINT_DIR" "$opts")"

  info "Partition   : $PARTITION"
  info "UUID        : $uuid"
  info "Filesystem  : $actual_fstype"
  info "Mountpoint  : $MOUNTPOINT_DIR"
  info "fstab type  : $FS_TYPE"
  info "Options     : $opts"

  backup_fstab
  write_updated_fstab "$uuid" "$MOUNTPOINT_DIR" "$entry"
  info "Updated $FSTAB_PATH successfully."

  mount_now "$MOUNTPOINT_DIR"

  if findmnt --target "$MOUNTPOINT_DIR" >/dev/null 2>&1; then
    info "Mounted successfully:"
    findmnt --target "$MOUNTPOINT_DIR"
  else
    warn "fstab was updated, but the mount is not currently active."
    warn "It should still mount on next boot if the volume is clean."
  fi
}

main "$@"
