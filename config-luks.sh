#!/usr/bin/env bash

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# configure-crypt-grub-mkinitcpio.sh
#
# Configure:
#   - /etc/default/grub
#   - /etc/mkinitcpio.conf
#   - /etc/crypttab   (systemd mode only)
#
# Target layout:
#   LVM on LUKS, with root on an LV and optional hibernation resume from swap.
#
# Modes:
#   - systemd : mkinitcpio uses systemd + sd-encrypt
#   - udev    : mkinitcpio uses udev + encrypt
#
# Notes:
#   - In systemd mode, rd.luks.name= expects the LUKS UUID, not /dev/sdXN.
#   - In udev mode, cryptdevice= uses the raw encrypted device path or UUID.
#   - This script prefers persistent identifiers where practical.
# -----------------------------------------------------------------------------

SCRIPT_NAME="${0##*/}"
ROOT_PREFIX="/"
ROOT_MOUNT="/"
MODE="systemd"
APPLY=0
REBUILD=0
FORCE=0
DRY_RUN=0
VERBOSE=0
WRITE_CRYPTTAB=1

LUKS_MAPPER_NAME=""
ENCRYPTED_PARTITION=""
ENCRYPTED_PARTITION_UUID=""
VG_NAME=""
ROOT_LV_NAME=""
SWAP_SOURCE=""
SWAP_UUID=""
LUKS_OPTIONS="discard"
ROOT_FS_FLAGS="rw"
LSM_VALUE="landlock,lockdown,yama,integrity,apparmor,bpf"
GRUB_CFG_PATH="/boot/grub/grub.cfg"

function usage() {
  cat <<'HELP_EOF'
Usage:
  configure-crypt-grub-mkinitcpio.sh [options]

Purpose:
  Configure GRUB and mkinitcpio for an LVM-on-LUKS Arch Linux installation,
  using either the mkinitcpio systemd/sd-encrypt path or the udev/encrypt path.

Important:
  This script edits configuration files. By default it only prints the planned
  values. Use --apply to write changes.

Options:
  -m, --module, --module-hook, --mkinitcpio-hook, --hook <mode>
      Mode: systemd | udev
      Default: systemd

  -r, --root <path>
      Root prefix of the installed system.
      Example: /        (current system)
               /mnt     (mounted target system before chroot)
      Default: /

  --root-mount <path>
      Mountpoint whose source should be treated as the target root LV.
      Usually identical to --root for pre-chroot usage.
      Default: same as --root

  --mapper-name <name>
      LUKS mapper name, e.g. cryptroot

  --encrypted-partition <path>
      Raw encrypted partition, e.g. /dev/nvme0n1p7

  --vg-name <name>
      LVM volume group name

  --root-lv <name>
      Root logical volume name, e.g. root

  --swap-source <path>
      Swap device or partition path used for resume UUID detection

  --swap-uuid <uuid>
      Explicit swap UUID for resume=

  --grub-cfg <path>
      grub-mkconfig output path relative to the target root prefix
      Default: /boot/grub/grub.cfg

  --no-crypttab
      Do not rewrite /etc/crypttab in systemd mode

  --luks-options <opts>
      LUKS option string for kernel cmdline / crypttab
      Default: discard

  --lsm <list>
      Value for lsm= kernel parameter
      Default: landlock,lockdown,yama,integrity,apparmor,bpf

  --apply
      Write changes to disk

  --rebuild
      After writing files, run mkinitcpio -P and grub-mkconfig

  --force
      Continue even if a few non-critical validations fail

  --dry-run
      Print what would be written; do not modify files

  -v, --verbose
      Verbose output

  -h, --help
      Show this help text

Examples:
  configure-crypt-grub-mkinitcpio.sh

  configure-crypt-grub-mkinitcpio.sh \
    --root /mnt \
    --root-mount /mnt \
    --module systemd \
    --apply

  configure-crypt-grub-mkinitcpio.sh \
    --module udev \
    --mapper-name cryptroot \
    --encrypted-partition /dev/nvme0n1p7 \
    --vg-name vg0 \
    --root-lv root \
    --swap-source /dev/vg0/swap \
    --apply --rebuild
HELP_EOF
}

function log() {
  printf '%s\n' "$*"
}

function vlog() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    printf '%s\n' "$*"
  fi
}

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
}

function trim() {
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

function lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

function ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script as root."
  fi
}

function backup_file() {
  local file="$1"
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  if [[ -e "$file" ]]; then
    cp -a -- "$file" "${file}.bak.${ts}"
    vlog "Backup created: ${file}.bak.${ts}"
  fi
}

function target_path() {
  local rel="$1"

  if [[ "$ROOT_PREFIX" == "/" ]]; then
    printf '%s\n' "$rel"
  else
    printf '%s%s\n' "$ROOT_PREFIX" "$rel"
  fi
}

function validate_target_dirs() {
  [[ -d "$ROOT_PREFIX" ]] || die "Root prefix does not exist: $ROOT_PREFIX"
  [[ -d "$(target_path /etc)" ]] || die "Missing target /etc under: $ROOT_PREFIX"
}

function parse_args() {
  local arg

  while [[ "$#" -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      -m|--module|--module-hook|--mkinitcpio-hook|--hook)
        [[ "$#" -ge 2 ]] || die "Missing value after $1"
        MODE="$(lower "$2")"
        shift 2
        ;;
      -r|--root)
        [[ "$#" -ge 2 ]] || die "Missing value after $1"
        ROOT_PREFIX="$2"
        ROOT_MOUNT="$2"
        shift 2
        ;;
      --root-mount)
        [[ "$#" -ge 2 ]] || die "Missing value after $1"
        ROOT_MOUNT="$2"
        shift 2
        ;;
      --mapper-name)
        [[ "$#" -ge 2 ]] || die "Missing value after $1"
        LUKS_MAPPER_NAME="$2"
        shift 2
        ;;
      --encrypted-partition)
        [[ "$#" -ge 2 ]] || die "Missing value after $1"
        ENCRYPTED_PARTITION="$2"
        shift 2
        ;;
      --vg-name)
        [[ "$#" -ge 2 ]] || die "Missing value after $1"
        VG_NAME="$2"
        shift 2
        ;;
      --root-lv)
        [[ "$#" -ge 2 ]] || die "Missing value after $1"
        ROOT_LV_NAME="$2"
        shift 2
        ;;
      --swap-source)
        [[ "$#" -ge 2 ]] || die "Missing value after $1"
        SWAP_SOURCE="$2"
        shift 2
        ;;
      --swap-uuid)
        [[ "$#" -ge 2 ]] || die "Missing value after $1"
        SWAP_UUID="$2"
        shift 2
        ;;
      --grub-cfg)
        [[ "$#" -ge 2 ]] || die "Missing value after $1"
        GRUB_CFG_PATH="$2"
        shift 2
        ;;
      --luks-options)
        [[ "$#" -ge 2 ]] || die "Missing value after $1"
        LUKS_OPTIONS="$2"
        shift 2
        ;;
      --lsm)
        [[ "$#" -ge 2 ]] || die "Missing value after $1"
        LSM_VALUE="$2"
        shift 2
        ;;
      --no-crypttab)
        WRITE_CRYPTTAB=0
        shift
        ;;
      --apply)
        APPLY=1
        shift
        ;;
      --rebuild)
        REBUILD=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
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

  case "$MODE" in
    systemd|udev) ;;
    *) die "Invalid mode: $MODE (expected: systemd or udev)" ;;
  esac
}

function detect_root_lv_from_mount() {
  local source

  source="$(findmnt -no SOURCE -- "$ROOT_MOUNT" 2>/dev/null | trim || true)"
  [[ -n "$source" ]] || return 1

  vlog "Detected root mount source: $source"

  if [[ "$source" =~ ^/dev/mapper/([^/-]+)-(.+)$ ]]; then
    if [[ -z "$VG_NAME" ]]; then
      VG_NAME="${BASH_REMATCH[1]}"
    fi
    if [[ -z "$ROOT_LV_NAME" ]]; then
      ROOT_LV_NAME="${BASH_REMATCH[2]}"
    fi
    return 0
  fi

  if lvs --noheadings -o vg_name,lv_name "$source" >/dev/null 2>&1; then
    read -r VG_NAME ROOT_LV_NAME < <(
      lvs --noheadings -o vg_name,lv_name "$source" |
        awk 'NF >= 2 { print $1, $2; exit }'
    )
    return 0
  fi

  return 1
}

function detect_vg_and_root_lv() {
  if [[ -n "$VG_NAME" && -n "$ROOT_LV_NAME" ]]; then
    return 0
  fi

  detect_root_lv_from_mount || true

  [[ -n "$VG_NAME" ]] || return 1
  [[ -n "$ROOT_LV_NAME" ]] || return 1
  return 0
}

function detect_mapper_name_from_pvs() {
  local pv_name

  pv_name="$(pvs --noheadings -o pv_name 2>/dev/null | trim | head -n1 || true)"
  [[ -n "$pv_name" ]] || return 1

  if [[ "$pv_name" =~ ^/dev/mapper/(.+)$ ]]; then
    LUKS_MAPPER_NAME="${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

function detect_encrypted_partition_from_mapper() {
  local device

  [[ -n "$LUKS_MAPPER_NAME" ]] || return 1

  device="$({ cryptsetup status "$LUKS_MAPPER_NAME" 2>/dev/null || true; } |
    awk '/^[[:space:]]*device:/ { print $2; exit }')"

  [[ -n "$device" ]] || return 1
  ENCRYPTED_PARTITION="$device"
  return 0
}

function detect_luks_mapper_and_partition() {
  if [[ -z "$LUKS_MAPPER_NAME" ]]; then
    detect_mapper_name_from_pvs || true
  fi

  if [[ -z "$ENCRYPTED_PARTITION" ]]; then
    detect_encrypted_partition_from_mapper || true
  fi

  [[ -n "$LUKS_MAPPER_NAME" ]] || return 1
  [[ -n "$ENCRYPTED_PARTITION" ]] || return 1
  return 0
}

function detect_encrypted_partition_uuid() {
  [[ -n "$ENCRYPTED_PARTITION" ]] || return 1
  ENCRYPTED_PARTITION_UUID="$(blkid -o value -s UUID \
    "$ENCRYPTED_PARTITION" 2>/dev/null || true)"
  [[ -n "$ENCRYPTED_PARTITION_UUID" ]] || return 1
  return 0
}

function detect_swap_source() {
  local candidate

  [[ -n "$SWAP_SOURCE" ]] && return 0

  candidate="$(swapon --noheadings --raw --show=NAME \
    2>/dev/null | head -n1 || true)"
  if [[ -n "$candidate" ]]; then
    SWAP_SOURCE="$candidate"
    return 0
  fi

  if [[ -n "$VG_NAME" ]]; then
    candidate="$(lvs --noheadings -o lv_path "$VG_NAME" 2>/dev/null |
      awk '/swap/ { print $1; exit }' || true)"
    if [[ -n "$candidate" ]]; then
      SWAP_SOURCE="$candidate"
      return 0
    fi
  fi

  return 1
}

function detect_swap_uuid() {
  [[ -n "$SWAP_UUID" ]] && return 0
  [[ -n "$SWAP_SOURCE" ]] || detect_swap_source || return 1

  SWAP_UUID="$(blkid -o value -s UUID "$SWAP_SOURCE" 2>/dev/null || true)"
  [[ -n "$SWAP_UUID" ]] || return 1
  return 0
}

function require_value() {
  local name="$1"
  local value="$2"

  [[ -n "$value" ]] || die "Missing required value: $name"
}

function maybe_warn_or_die() {
  local message="$1"

  if [[ "$FORCE" -eq 1 ]]; then
    printf 'Warning: %s\n' "$message" >&2
  else
    die "$message"
  fi
}

function validate_detected_values() {
  require_value "mode" "$MODE"
  require_value "luks mapper name" "$LUKS_MAPPER_NAME"
  require_value "encrypted partition" "$ENCRYPTED_PARTITION"
  require_value "encrypted partition UUID" "$ENCRYPTED_PARTITION_UUID"
  require_value "volume group name" "$VG_NAME"
  require_value "root logical volume name" "$ROOT_LV_NAME"

  if [[ -z "$SWAP_UUID" ]]; then
    maybe_warn_or_die \
      "Could not determine swap UUID. Pass --swap-source or --swap-uuid."
  fi
}

function generate_grub_cmdline() {
  local root_path
  root_path="/dev/${VG_NAME}/${ROOT_LV_NAME}"

  if [[ "$MODE" == "systemd" ]]; then
    printf '%s\n' \
      "rd.luks.name=${ENCRYPTED_PARTITION_UUID}=${LUKS_MAPPER_NAME} \
rd.luks.options=${ENCRYPTED_PARTITION_UUID}=${LUKS_OPTIONS} \
root=${root_path}${SWAP_UUID:+ resume=UUID=${SWAP_UUID}} \
${ROOT_FS_FLAGS} lsm=${LSM_VALUE}"
  else
    printf '%s\n' \
      "cryptdevice=UUID=${ENCRYPTED_PARTITION_UUID}:${LUKS_MAPPER_NAME}:\
${LUKS_OPTIONS} root=${root_path}${SWAP_UUID:+ resume=UUID=${SWAP_UUID}} \
${ROOT_FS_FLAGS} lsm=${LSM_VALUE}"
  fi
}

function generate_mkinitcpio_hooks() {
  if [[ "$MODE" == "systemd" ]]; then
    printf '%s\n' \
      'HOOKS=(base systemd autodetect microcode modconf block sd-vconsole sd-encrypt lvm2 filesystems fsck sd-shutdown)'
  else
    printf '%s\n' \
      'HOOKS=(base udev autodetect microcode modconf block keyboard keymap consolefont encrypt lvm2 filesystems fsck shutdown)'
  fi
}

function write_file() {
  local file="$1"
  local tmp="$2"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "--- ${file} (planned) ---"
    cat -- "$tmp"
    return 0
  fi

  backup_file "$file"
  install -Dm644 -- "$tmp" "$file"
  vlog "Wrote: $file"
}

function upsert_kv_line() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp

  tmp="$(mktemp)"

  if [[ -f "$file" ]]; then
    awk -v key="$key" -v value="$value" '
      BEGIN { done = 0 }
      $0 ~ "^" key "=" {
        print key "=\"" value "\""
        done = 1
        next
      }
      { print }
      END {
        if (!done) {
          print key "=\"" value "\""
        }
      }
    ' "$file" > "$tmp"
  else
    printf '%s="%s"\n' "$key" "$value" > "$tmp"
  fi

  write_file "$file" "$tmp"
  rm -f -- "$tmp"
}

function upsert_raw_line() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp

  tmp="$(mktemp)"

  if [[ -f "$file" ]]; then
    awk -v key="$key" -v value="$value" '
      BEGIN { done = 0 }
      $0 ~ "^" key "=" {
        print key "=" value
        done = 1
        next
      }
      { print }
      END {
        if (!done) {
          print key "=" value
        }
      }
    ' "$file" > "$tmp"
  else
    printf '%s=%s\n' "$key" "$value" > "$tmp"
  fi

  write_file "$file" "$tmp"
  rm -f -- "$tmp"
}

function render_crypttab_template() {
  local file="$1"
  cat > "$file" <<CRYPTTAB_EOF
# Configuration for encrypted block devices.
# See crypttab(5) for details.

# NOTE: Do not list your root (/) partition here, it must be set up
#       beforehand by the initramfs (/etc/mkinitcpio.conf).

# <name>       <device>                                     <password>              <options>
# home         UUID=b8ad5c18-f445-495d-9095-c9ec4f9d2f37    /etc/mypassword1
# data1        /dev/sda3                                    /etc/mypassword2
# data2        /dev/sda5                                    /etc/cryptfs.key
# swap         /dev/sdx4                                    /dev/urandom            swap,cipher=aes-cbc-essiv:sha256,size=256
# vol          /dev/sdb7                                    none
${LUKS_MAPPER_NAME} UUID=${ENCRYPTED_PARTITION_UUID} none luks,${LUKS_OPTIONS}
CRYPTTAB_EOF
}

function configure_grub_defaults() {
  local file cmdline preload
  file="$(target_path /etc/default/grub)"
  cmdline="$(generate_grub_cmdline)"
  preload='part_gpt part_msdos luks cryptodisk lvm ext2'

  upsert_kv_line  "$file" 'GRUB_CMDLINE_LINUX'      "$cmdline"
  upsert_kv_line  "$file" 'GRUB_PRELOAD_MODULES'    "$preload"
  upsert_raw_line "$file" 'GRUB_ENABLE_CRYPTODISK'  'y'
  upsert_kv_line  "$file" 'GRUB_TIMEOUT_STYLE'      'menu'
  upsert_kv_line  "$file" 'GRUB_TERMINAL_INPUT'     'console'
  upsert_kv_line  "$file" 'GRUB_GFXMODE'            'auto'
  upsert_kv_line  "$file" 'GRUB_GFXPAYLOAD_LINUX'   'keep'
  upsert_raw_line "$file" 'GRUB_DISABLE_RECOVERY'   'true'
  upsert_raw_line "$file" 'GRUB_DISABLE_OS_PROBER'  'false'
}

function configure_mkinitcpio() {
  local file tmp hooks_line
  file="$(target_path /etc/mkinitcpio.conf)"
  tmp="$(mktemp)"
  hooks_line="$(generate_mkinitcpio_hooks)"

  if [[ -f "$file" ]]; then
    awk \
      -v hooks_line="$hooks_line" '
      BEGIN {
        modules_done = 0
        binaries_done = 0
        hooks_done = 0
        compression_done = 0
        compression_opts_done = 0
      }
      /^MODULES=/ {
        print "MODULES=()"
        modules_done = 1
        next
      }
      /^BINARIES=/ {
        print "BINARIES=()"
        binaries_done = 1
        next
      }
      /^HOOKS=/ {
        print hooks_line
        hooks_done = 1
        next
      }
      /^COMPRESSION=/ {
        print "COMPRESSION=\"zstd\""
        compression_done = 1
        next
      }
      /^COMPRESSION_OPTIONS=/ {
        print "COMPRESSION_OPTIONS=(\"--fast\")"
        compression_opts_done = 1
        next
      }
      { print }
      END {
        if (!modules_done) {
          print "MODULES=()"
        }
        if (!binaries_done) {
          print "BINARIES=()"
        }
        if (!hooks_done) {
          print hooks_line
        }
        if (!compression_done) {
          print "COMPRESSION=\"zstd\""
        }
        if (!compression_opts_done) {
          print "COMPRESSION_OPTIONS=(\"--fast\")"
        }
      }
    ' "$file" > "$tmp"
  else
    cat > "$tmp" <<MKINITCPIO_EOF
MODULES=()
BINARIES=()
FILES=()
${hooks_line}
COMPRESSION="zstd"
COMPRESSION_OPTIONS=("--fast")
MKINITCPIO_EOF
  fi

  write_file "$file" "$tmp"
  rm -f -- "$tmp"
}

function configure_crypttab() {
  local file tmp
  file="$(target_path /etc/crypttab)"
  tmp="$(mktemp)"

  render_crypttab_template "$tmp"
  write_file "$file" "$tmp"
  rm -f -- "$tmp"
}

function print_summary() {
  cat <<SUMMARY_EOF
Mode                  : ${MODE}
Target root prefix    : ${ROOT_PREFIX}
Target root mount     : ${ROOT_MOUNT}
LUKS mapper name      : ${LUKS_MAPPER_NAME}
Encrypted partition   : ${ENCRYPTED_PARTITION}
Encrypted part UUID   : ${ENCRYPTED_PARTITION_UUID}
Volume group          : ${VG_NAME}
Root LV               : ${ROOT_LV_NAME}
Swap source           : ${SWAP_SOURCE:-<undetected>}
Swap UUID             : ${SWAP_UUID:-<undetected>}
GRUB cmdline          : $(generate_grub_cmdline)
mkinitcpio HOOKS      : $(generate_mkinitcpio_hooks | sed 's/^HOOKS=//')
Write crypttab        : $( [[ "$MODE" == "systemd" && "$WRITE_CRYPTTAB" -eq 1 ]] && printf yes || printf no )
Apply changes         : $( [[ "$APPLY" -eq 1 ]] && printf yes || printf no )
Rebuild initramfs     : $( [[ "$REBUILD" -eq 1 ]] && printf yes || printf no )
Dry run               : $( [[ "$DRY_RUN" -eq 1 ]] && printf yes || printf no )
SUMMARY_EOF
}

function rebuild_boot_artifacts() {
  local grub_cfg_abs
  grub_cfg_abs="$(target_path "$GRUB_CFG_PATH")"

  if [[ "$ROOT_PREFIX" == "/" ]]; then
    mkinitcpio -P
    grub-mkconfig -o "$grub_cfg_abs"
  else
    arch-chroot "$ROOT_PREFIX" mkinitcpio -P
    arch-chroot "$ROOT_PREFIX" grub-mkconfig -o "$GRUB_CFG_PATH"
  fi
}

function main() {
  parse_args "$@"
  ensure_root
  validate_target_dirs

  require_cmd awk
  require_cmd blkid
  require_cmd cryptsetup
  require_cmd findmnt
  require_cmd grub-mkconfig
  require_cmd install
  require_cmd lvs
  require_cmd pvs

  if [[ "$ROOT_PREFIX" != "/" ]]; then
    require_cmd arch-chroot
  fi

  detect_vg_and_root_lv || true
  detect_luks_mapper_and_partition || true
  detect_encrypted_partition_uuid || true
  detect_swap_uuid || true
  validate_detected_values

  print_summary

  if [[ "$APPLY" -ne 1 && "$DRY_RUN" -ne 1 ]]; then
    log
    log "No files were modified. Re-run with --apply to write changes."
    exit 0
  fi

  configure_grub_defaults
  configure_mkinitcpio

  if [[ "$MODE" == "systemd" && "$WRITE_CRYPTTAB" -eq 1 ]]; then
    configure_crypttab
  fi

  if [[ "$REBUILD" -eq 1 && "$DRY_RUN" -ne 1 ]]; then
    rebuild_boot_artifacts
  fi
}

main "$@"
