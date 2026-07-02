#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Build a custom ArchISO with local LVM rescue helpers included.
# -----------------------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

SOURCE_PROFILE="${SOURCE_PROFILE:-${SCRIPT_DIR}/profile}"
LVM_DIR="${LVM_DIR:-${REPO_ROOT}/lvm_scripts}"
BUILD_ROOT="${BUILD_ROOT:-/var/tmp/archiso-lvm-rescue}"
BUILD_PROFILE="${BUILD_PROFILE:-${BUILD_ROOT}/profile}"
WORK_DIR="${WORK_DIR:-${BUILD_ROOT}/work}"
OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/out}"

PREPARE_ONLY=0
CLEAN_ONLY=0

function usage() {
  cat <<EOF
${SCRIPT_NAME} - build the Heini Arch LVM rescue ISO.

Usage:
  sudo ./${SCRIPT_NAME} [options]

Options:
  --prepare-only       Stage the build profile, but do not run mkarchiso.
  --clean              Remove the temporary build tree and exit.
  --profile-dir DIR    Source profile directory. Default: ${SOURCE_PROFILE}
  --lvm-dir DIR        Source LVM script directory. Default: ${LVM_DIR}
  --work-dir DIR       mkarchiso work directory. Default: ${WORK_DIR}
  --out-dir DIR        ISO output directory. Default: ${OUT_DIR}
  -h, --help           Show this help.

Environment:
  BUILD_ROOT           Base temporary directory. Default: ${BUILD_ROOT}
  BUILD_PROFILE        Staged profile directory. Default: ${BUILD_PROFILE}
  SOURCE_PROFILE       Source profile directory.
  LVM_DIR              Source LVM script directory.
  WORK_DIR             mkarchiso work directory.
  OUT_DIR              ISO output directory.

The script copies the source profile to BUILD_PROFILE, stages the current
top-level files from LVM_DIR, then runs:

  mkarchiso -v -w WORK_DIR -o OUT_DIR BUILD_PROFILE
EOF
}

function log() {
  printf '==> %s\n' "$*"
}

function die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

function require_root() {
  [[ "$EUID" -eq 0 ]] || die "Run as root: sudo ./${SCRIPT_NAME}"
}

function require_cmds() {
  local cmd

  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing command: ${cmd}"
  done
}

function parse_args() {
  while (($#)); do
    case "$1" in
    --prepare-only)
      PREPARE_ONLY=1
      shift
      ;;
    --clean)
      CLEAN_ONLY=1
      shift
      ;;
    --profile-dir)
      [[ $# -ge 2 ]] || die "--profile-dir requires a directory"
      SOURCE_PROFILE="$2"
      shift 2
      ;;
    --lvm-dir)
      [[ $# -ge 2 ]] || die "--lvm-dir requires a directory"
      LVM_DIR="$2"
      shift 2
      ;;
    --work-dir)
      [[ $# -ge 2 ]] || die "--work-dir requires a directory"
      WORK_DIR="$2"
      shift 2
      ;;
    --out-dir)
      [[ $# -ge 2 ]] || die "--out-dir requires a directory"
      OUT_DIR="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
    esac
  done
}

function validate_inputs() {
  [[ -d "$SOURCE_PROFILE" ]] ||
    die "Profile directory does not exist: ${SOURCE_PROFILE}"
  [[ -f "${SOURCE_PROFILE}/profiledef.sh" ]] ||
    die "Missing profiledef.sh in: ${SOURCE_PROFILE}"
  [[ -f "${SOURCE_PROFILE}/packages.x86_64" ]] ||
    die "Missing packages.x86_64 in: ${SOURCE_PROFILE}"

  [[ -d "$LVM_DIR" ]] || die "LVM script directory does not exist: ${LVM_DIR}"
  [[ -f "${LVM_DIR}/lvm-math-inspect.sh" ]] ||
    die "Missing lvm-math-inspect.sh in: ${LVM_DIR}"
  [[ -f "${LVM_DIR}/lvm-organize-resize-logical-partitions.sh" ]] ||
    die "Missing safer LVM move script in: ${LVM_DIR}"
}

function should_install_executable() {
  local file="$1"
  local magic=""

  [[ -x "$file" || "$file" == *.sh ]] && return 0

  magic="$(head -c 2 "$file" 2>/dev/null || true)"
  [[ "$magic" == "#!" ]]
}

function copy_lvm_files() {
  local root_scripts="${BUILD_PROFILE}/airootfs/root/lvm-scripts"
  local bin_dir="${BUILD_PROFILE}/airootfs/usr/local/bin"
  local file
  local mode
  local copied=0

  install -d -m 0755 "$root_scripts"
  install -d -m 0755 "$bin_dir"

  while IFS= read -r -d '' file; do
    mode=0644
    if should_install_executable "$file"; then
      mode=0755
    fi

    install -m "$mode" "$file" "${root_scripts}/$(basename "$file")"
    copied=$((copied + 1))
  done < <(find "$LVM_DIR" -maxdepth 1 -type f -print0)

  ((copied > 0)) || die "No regular files found in: ${LVM_DIR}"

  install -m 0755 \
    "${LVM_DIR}/lvm-math-inspect.sh" \
    "${bin_dir}/lvm-math-inspect"

  install -m 0755 \
    "${LVM_DIR}/lvm-organize-resize-logical-partitions.sh" \
    "${bin_dir}/lvm-move-space-safe"
}

function write_live_readme() {
  local readme="${BUILD_PROFILE}/airootfs/root/lvm-scripts/README.txt"

  cat > "$readme" <<'EOF'
LVM rescue helpers included in this ISO

Primary commands on PATH:
  lvm-math-inspect
  lvm-move-space-safe

All copied files:
  /root/lvm-scripts/

Initial rescue commands:
  lsblk -f
  lvs -a -o+devices
  vgs
  findmnt

For encrypted LVM systems:
  cryptsetup open /dev/<device> <name>
  vgchange -ay
EOF

  chmod 0644 "$readme"
}

function prepare_profile() {
  log "Preparing staged profile: ${BUILD_PROFILE}"

  rm -rf "$BUILD_PROFILE"
  install -d -m 0755 "$BUILD_ROOT"
  install -d -m 0755 "$OUT_DIR"

  rsync -a --delete "${SOURCE_PROFILE}/" "${BUILD_PROFILE}/"

  log "Copying LVM files from: ${LVM_DIR}"
  copy_lvm_files
  write_live_readme
}

function build_iso() {
  log "Building ISO"
  log "Work directory: ${WORK_DIR}"
  log "Output directory: ${OUT_DIR}"

  mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$BUILD_PROFILE"
}

function chown_output_to_sudo_user() {
  if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
    chown -R "${SUDO_UID}:${SUDO_GID}" "$OUT_DIR"
  fi
}

function clean_build_tree() {
  log "Removing temporary build tree: ${BUILD_ROOT}"
  rm -rf "$BUILD_ROOT"
}

function main() {
  parse_args "$@"
  require_cmds rsync install chmod rm find head

  if [[ "$CLEAN_ONLY" -eq 1 ]]; then
    require_root
    clean_build_tree
    exit 0
  fi

  validate_inputs
  prepare_profile

  if [[ "$PREPARE_ONLY" -eq 1 ]]; then
    log "Prepared profile only; mkarchiso was not run."
    exit 0
  fi

  require_root
  require_cmds mkarchiso chown
  build_iso
  chown_output_to_sudo_user

  log "Done. ISO output is in: ${OUT_DIR}"
}

main "$@"
