#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# cgroup2-remount: install/verify/remove a systemd oneshot unit that remounts
# /sys/fs/cgroup with hardened mount options (nosuid,nodev,noexec).
#
# Intended for embedding in a custom ISO or post-install provisioning.
#
# Safety notes:
# - This script does NOT create the cgroup2 mount. It only remounts an existing
#   mountpoint (systemd already mounts cgroup2 on systemd hosts).
# - Rollback is trivial: disable unit + remove unit file + remove wants symlink.
# -----------------------------------------------------------------------------

set -euo pipefail

# ---------------------------#
# Defaults
# ---------------------------#
readonly PROG="${0##*/}"

UNIT_NAME="cgroup2-remount.service"
UNIT_DIR="/etc/systemd/system"
UNIT_PATH="${UNIT_DIR}/${UNIT_NAME}"
WANTS_LINK="${UNIT_DIR}/multi-user.target.wants/${UNIT_NAME}"
MOUNTPOINT="/sys/fs/cgroup"

# Options to enforce on the cgroup2 mount. You may add nsdelegate, etc., if you
# truly need it (typically for some container delegation scenarios).
OPTIONS="rw,nosuid,nodev,noexec,relatime"

HELP_PAGER="${HELP_PAGER:-}"

# ---------------------------#
# Helpers
# ---------------------------#
function _pager() {
  if [[ -n "$HELP_PAGER" ]]; then
    printf '%s\n' "$HELP_PAGER"
    return 0
  fi

  if command -v less >/dev/null 2>&1; then
    printf '%s\n' "less -R"
    return 0
  fi

  printf '%s\n' "cat"
}

function die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

function need_root() {
  if [[ "$EUID" -ne 0 ]]; then
    die "This action requires root. Re-run with sudo."
  fi
}

function have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

function normalize_mode() {
  local v="${1:-}"
  v="${v,,}"
  printf '%s\n' "$v"
}

function show_help() {
  local pager
  pager="$(_pager)"

  cat <<'EOF' | eval "${pager}"
NAME
  cgroup2-remount - install/verify/remove a systemd unit to remount /sys/fs/cgroup

SYNOPSIS
  cgroup2-remount --install [--options OPTS]
  cgroup2-remount --verify  [--options OPTS]
  cgroup2-remount --apply   [--options OPTS]
  cgroup2-remount --remove
  cgroup2-remount --status
  cgroup2-remount --print-unit [--options OPTS]
  cgroup2-remount --help

DESCRIPTION
  On systemd systems, cgroup2 is typically mounted automatically at:
    /sys/fs/cgroup

  This script creates a oneshot unit that performs:
    mount -o remount,<OPTS> /sys/fs/cgroup

  It does not create the mount; it only remounts if the mountpoint is present.

OPTIONS
  --install
      Write the unit file, set root:root ownership and 0644 permissions,
      daemon-reload, and enable the unit (but does not necessarily run it).

  --verify
      Verify whether /sys/fs/cgroup is mounted as cgroup2 and whether the
      requested mount options are active. Also checks unit presence/enabled.

  --apply
      Equivalent to: --install then start the unit immediately then --verify.

  --remove
      Disable the unit, remove unit file and wants symlink, daemon-reload.

  --status
      Print unit enabled state (if available), and current mount options.

  --print-unit
      Print the unit file content that would be written (no changes).

  --options OPTS
      Comma-separated mount options to require, e.g.:
        rw,nosuid,nodev,noexec,relatime
      Comparison is set-based (order does not matter). Case-insensitive.

  -h, --help
      Show this help.

ENVIRONMENT
  HELP_PAGER
      Pager command for help output (default: 'less -R' if available, else cat).

EXIT STATUS
  0 on success, non-zero on error.

EXAMPLES
  Install and apply immediately:
    sudo cgroup2-remount --apply

  Verify:
    cgroup2-remount --verify

  Remove:
    sudo cgroup2-remount --remove
EOF
}

# ---------------------------#
# Core logic
# ---------------------------#
function unit_content() {
  local opts="${1}"
  cat <<EOF
[Unit]
Description=Remount cgroup2 with hardened mount options
DefaultDependencies=no
After=local-fs.target
ConditionPathIsMountPoint=${MOUNTPOINT}

[Service]
Type=oneshot
ExecStart=/usr/bin/mount -o remount,${opts} ${MOUNTPOINT}

[Install]
WantedBy=multi-user.target
EOF
}

function write_unit() {
  local opts="${1}"

  need_root
  mkdir -p "$UNIT_DIR"
  unit_content "$opts" >"$UNIT_PATH"
  chown root:root "$UNIT_PATH"
  chmod 0644 "$UNIT_PATH"
}

function daemon_reload() {
  need_root
  systemctl daemon-reload
}

function enable_unit() {
  need_root
  systemctl enable "$UNIT_NAME"
}

function start_unit_now() {
  need_root
  systemctl start "$UNIT_NAME"
}

function disable_unit() {
  need_root
  systemctl disable "$UNIT_NAME" 2>/dev/null || true
}

function remove_files() {
  need_root
  rm -f "$WANTS_LINK" "$UNIT_PATH"
}

function get_mount_info() {
  # Prints: SOURCE TARGET FSTYPE OPTIONS
  findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS "$MOUNTPOINT" 2>/dev/null || true
}

function parse_opts_csv_to_set() {
  # Normalize to newline-separated unique options.
  local csv="${1}"
  # shellcheck disable=SC2001
  printf '%s\n' "$csv" |
    tr ',' '\n' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//' |
    tr '[:upper:]' '[:lower:]' |
    awk 'NF { seen[$0]=1 } END { for (k in seen) print k }' |
    sort
}

function verify_mount_has_opts() {
  local want_csv="${1}"
  local info fstype got_csv
  info="$(get_mount_info)"

  if [[ -z "$info" ]]; then
    die "Mountpoint not found: ${MOUNTPOINT} (is cgroup2 mounted?)"
  fi

  # SOURCE TARGET FSTYPE OPTIONS
  # shellcheck disable=SC2206
  local parts=("$info")
  fstype="${parts[2]}"
  got_csv="${parts[3]}"

  if [[ "$fstype" != "cgroup2" ]]; then
    die "Expected FSTYPE=cgroup2 for ${MOUNTPOINT}, got: ${fstype}"
  fi

  local want_set got_set
  want_set="$(parse_opts_csv_to_set "$want_csv")"
  got_set="$(parse_opts_csv_to_set "$got_csv")"

  # Check each wanted option is present.
  local missing=()
  while IFS= read -r opt; do
    if ! grep -qxF "$opt" <<<"$got_set"; then
      missing+=("$opt")
    fi
  done <<<"$want_set"

  if ((${#missing[@]} > 0)); then
    printf 'Mount options on %s are missing:\n' "$MOUNTPOINT" >&2
    printf '  %s\n' "${missing[@]}" >&2
    printf '\nCurrent options: %s\n' "$got_csv" >&2
    printf 'Wanted options:  %s\n' "$want_csv" >&2
    return 1
  fi

  return 0
}

function verify_unit_state() {
  local ok=0

  if [[ -f "$UNIT_PATH" ]]; then
    printf 'Unit file: present (%s)\n' "$UNIT_PATH"
  else
    printf 'Unit file: MISSING (%s)\n' "$UNIT_PATH"
    ok=1
  fi

  if have_cmd systemctl; then
    if systemctl is-enabled --quiet "$UNIT_NAME" 2>/dev/null; then
      printf 'Unit enabled: yes\n'
    else
      printf 'Unit enabled: no\n'
      ok=1
    fi
  else
    printf 'systemctl: not found (cannot check enabled state)\n'
    ok=1
  fi

  return "$ok"
}

function action_install() {
  local opts="${1}"

  write_unit "$opts"
  daemon_reload
  enable_unit

  printf 'Installed and enabled: %s\n' "$UNIT_NAME"
}

function action_apply() {
  local opts="${1}"

  action_install "$opts"
  start_unit_now

  printf 'Applied remount now.\n'
  action_verify "$opts"
}

function action_verify() {
  local opts="${1}"

  local info
  info="$(get_mount_info)"
  printf 'Mount: %s\n' "${info:-<none>}"

  local unit_ok=0
  local mount_ok=0

  if verify_unit_state; then
    unit_ok=0
  else
    unit_ok=1
  fi

  if verify_mount_has_opts "$opts"; then
    printf 'Mount options: OK (contains all requested)\n'
    mount_ok=0
  else
    printf 'Mount options: NOT OK\n'
    mount_ok=1
  fi

  if ((unit_ok == 0 && mount_ok == 0)); then
    printf 'VERIFY: SUCCESS\n'
    return 0
  fi

  printf 'VERIFY: FAILED\n' >&2
  return 1
}

function action_remove() {
  need_root

  disable_unit
  remove_files
  daemon_reload

  printf 'Removed: %s\n' "$UNIT_NAME"
}

function action_status() {
  local info
  info="$(get_mount_info)"
  printf 'Mount: %s\n' "${info:-<none>}"

  if have_cmd systemctl; then
    if systemctl is-enabled --quiet "$UNIT_NAME" 2>/dev/null; then
      printf 'Unit enabled: yes\n'
    else
      printf 'Unit enabled: no\n'
    fi
  else
    printf 'Unit enabled: unknown (systemctl not found)\n'
  fi

  if [[ -f "$UNIT_PATH" ]]; then
    printf 'Unit file: %s\n' "$UNIT_PATH"
  else
    printf 'Unit file: <missing>\n'
  fi
}

function action_print_unit() {
  unit_content "${1}"
}

# ---------------------------#
# Arg parsing
# ---------------------------#
MODE=""
while (($# > 0)); do
  case "$1" in
  --install | --apply | --verify | --remove | --status | --print-unit)
    MODE="$1"
    shift
    ;;
  --options)
    shift
    [[ $# -gt 0 ]] || die "--options requires a value"
    OPTIONS="$1"
    shift
    ;;
  -h | --help)
    show_help
    exit 0
    ;;
  *)
    die "Unknown argument: $1 (use --help)"
    ;;
  esac
done

[[ -n "$MODE" ]] || {
  show_help
  exit 1
}

# Normalize options string lightly (trim spaces, lowercase). Comparison is
# set-based later, so order does not matter.
OPTIONS="$(printf '%s' "$OPTIONS" | tr -d ' ')"
OPTIONS="${OPTIONS,,}"

# ---------------------------#
# Dispatch
# ---------------------------#
case "$(normalize_mode "$MODE")" in
--install) action_install "$OPTIONS" ;;
--apply) action_apply "$OPTIONS" ;;
--verify) action_verify "$OPTIONS" ;;
--remove) action_remove ;;
--status) action_status ;;
--print-unit) action_print_unit "$OPTIONS" ;;
*)
  die "Unhandled mode: ${MODE}"
  ;;
esac
