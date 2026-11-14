#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# gen-mirror — switch between Nordic and Turkey-adapted Arch mirror profiles.
# -----------------------------------------------------------------------------
# Usage:
#   gen-mirror turkey
#   gen-mirror nordic
#   gen-mirror              # refreshes the active profile
#
# On the first run, the installed mirrorlist is assumed to be Nordic.
# Each successful switch keeps copies at:
#   /etc/pacman.d/mirrorlist.nordic
#   /etc/pacman.d/mirrorlist.turkey
# -----------------------------------------------------------------------------

function usage() {
  cat <<'EOF'
Usage: gen-mirror [nordic|turkey]

  nordic  Select the original DK/SE/NO/FI/DE/NL mirror region.
  turkey  Select Türkiye and nearby European fallback regions.
  No argument refreshes the active profile (Nordic initially).
EOF
}

function fail() {
  printf 'gen-mirror: %s\n' "$*" >&2
  exit 1
}

function cleanup() {
  [[ -z "$candidate" ]] || rm -f -- "$candidate"
  [[ -z "$backup_tmp" ]] || rm -f -- "$backup_tmp"
  [[ -z "$profile_tmp" ]] || rm -f -- "$profile_tmp"
  [[ -z "$state_tmp" ]] || rm -f -- "$state_tmp"
}

if (( EUID != 0 )); then
  command -v sudo >/dev/null 2>&1 || {
    printf 'gen-mirror: run as root or install sudo.\n' >&2
    exit 1
  }
  exec sudo -- "$0" "$@"
fi

if (( $# > 1 )); then
  usage >&2
  exit 2
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

MIRROR_DIR="/etc/pacman.d"
MIRRORLIST="$MIRROR_DIR/mirrorlist"
STATE_FILE="$MIRROR_DIR/.gen-mirror-profile"
candidate=""
backup_tmp=""
profile_tmp=""
state_tmp=""

[[ -d "$MIRROR_DIR" ]] || fail "missing $MIRROR_DIR"
command -v reflector >/dev/null 2>&1 || fail "reflector is not installed"

if [[ -r "$STATE_FILE" ]]; then
  active_profile="$(<"$STATE_FILE")"
else
  # The list shown in the user's current setup uses the Nordic countries.
  active_profile="nordic"
fi

case "$active_profile" in
  nordic|turkey) ;;
  *) fail "invalid profile marker in $STATE_FILE" ;;
esac

target_profile="${1:-$active_profile}"

case "$target_profile" in
  nordic)
    countries="DK,SE,NO,FI,DE,NL"
    ;;
  turkey)
    countries="TR,BG,GR,RO,DE"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

candidate="$(mktemp "$MIRROR_DIR/.mirrorlist.$target_profile.XXXXXX")"
trap cleanup EXIT

reflector_args=(
  --verbose
  --country "$countries"
  --protocol https
  --age 12
  --completion-percent 100
  --sort rate
  --number 10
  --threads 1
  --connection-timeout 3
  --download-timeout 3
  --cache-timeout 0
  --save "$candidate"
)

if ! reflector "${reflector_args[@]}"; then
  fail "reflector failed; the active mirrorlist was left unchanged"
fi

if [[ ! -s "$candidate" ]] ||
  ! grep -qE '^[[:space:]]*Server[[:space:]]*=' "$candidate"; then
  fail "reflector produced no usable mirrors; active list left unchanged"
fi

backup_path="$MIRROR_DIR/mirrorlist.$active_profile"
if [[ -f "$MIRRORLIST" ]]; then
  backup_tmp="$(mktemp "$backup_path.XXXXXX")"
  install -m 0644 -- "$MIRRORLIST" "$backup_tmp"
  mv -f -- "$backup_tmp" "$backup_path"
  backup_tmp=""
fi

profile_path="$MIRROR_DIR/mirrorlist.$target_profile"
profile_tmp="$(mktemp "$profile_path.XXXXXX")"
install -m 0644 -- "$candidate" "$profile_tmp"
mv -f -- "$profile_tmp" "$profile_path"
profile_tmp=""

chmod 0644 "$candidate"
mv -f -- "$candidate" "$MIRRORLIST"
candidate=""

state_tmp="$(mktemp "$STATE_FILE.XXXXXX")"
printf '%s\n' "$target_profile" > "$state_tmp"
chmod 0644 "$state_tmp"
mv -f -- "$state_tmp" "$STATE_FILE"
state_tmp=""

printf 'Active profile: %s (%s)\n' "$target_profile" "$countries"
printf 'Saved profiles: %s and %s\n' \
  "$MIRROR_DIR/mirrorlist.nordic" \
  "$MIRROR_DIR/mirrorlist.turkey"
