#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Configure parallel AUR builds and skip check(), with reversible user overrides.
# Requires Bash, Python 3, and nproc (GNU coreutils). Run without sudo.
# -----------------------------------------------------------------------------
set -euo pipefail

function usage() {
  cat <<'HELP'
Usage: bash yay-build-speed.sh [OPTION]

  --apply           Skip checks and request eight jobs (default).
  --jobs N          Skip checks and request N concurrent jobs.
  --all             Use CPUs available to nproc at each future build.
  --for DURATION    Apply for e.g. 30m, 2h, or 1d (also ends on reboot).
  --until-reboot    Apply only during the current boot.
  --revert          Remove this script's overrides; restore prior settings.
  --status          Show this script's configuration block and target path.
  --help            Show this help.

Examples:
  bash yay-build-speed.sh --jobs 8
  bash yay-build-speed.sh --all
  bash yay-build-speed.sh --jobs 8 --for 2h
  bash yay-build-speed.sh --all --until-reboot
  bash yay-build-speed.sh --revert

Configuration:
  Uses the existing XDG pacman/makepkg.conf, otherwise ~/.makepkg.conf if
  present, otherwise creates the XDG file. Does not require sudo.
  Temporary blocks become inactive automatically; no timer service is needed.
  Expiry affects new builds, not builds already running. Expired blocks remain
  in the file until replaced or removed with --revert.
  Updates one marked block and backs up existing content before each change.
  Revert preserves unrelated edits, including settings that predate this script.
  Thus revert restores your prior defaults, not factory Arch settings.

Build behaviour:
  MAKEFLAGS controls Make; CMake and Cargo receive exported job settings.
  NPROC controls makepkg's own parallel work on versions supporting it.
  Direct Ninja and other tools may use their own parallelism defaults.
  A PKGBUILD can override these settings or explicitly disable parallel builds.
  !check skips all PKGBUILD check() functions, not only Python tests.
  Checks embedded in build()/package() still run. Integrity checks remain on.
  Existing yay --mflags settings are not changed by this script.
  MAKEFLAGS is replaced while applied; previous custom flags return on revert.

More jobs are not always faster: memory pressure and thermal throttling matter.
If a build exhausts RAM, reduce --jobs. Avoid changes during active builds.
HELP
}

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

# -----------------------------------------------------------------------------
# Parse arguments before accessing configuration.
# -----------------------------------------------------------------------------
action=apply
jobs=8
lifetime=permanent
duration=0
while (( $# )); do
  case "$1" in
    --apply) action=apply ;;
    --jobs)
      [[ $# -ge 2 ]] || die '--jobs requires one positive integer.'
      jobs=$2
      [[ $jobs =~ ^[1-9][0-9]*$ ]] || die 'Jobs must be positive.'
      shift
      ;;
    --all) jobs=all ;;
    --until-reboot)
      [[ $lifetime = permanent ]] || die 'Choose only one lifetime.'
      lifetime=boot
      ;;
    --for)
      [[ $# -ge 2 ]] || die '--for requires a duration such as 2h.'
      [[ $lifetime = permanent ]] || die 'Choose only one lifetime.'
      [[ $2 =~ ^[1-9][0-9]*[smhd]$ ]] || die 'Use e.g. 30m, 2h, or 1d.'
      duration=$2
      lifetime=timed
      shift
      ;;
    --revert) action=revert ;;
    --status) action=status ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)." ;;
  esac
  shift
done
[[ ${EUID} -ne 0 ]] || die 'Run as your normal user, without sudo.'
command -v python3 >/dev/null ||
  die 'Install Python 3 first: sudo pacman -S python'
command -v nproc >/dev/null || die 'nproc is required (coreutils).'

config_root=${XDG_CONFIG_HOME:-$HOME/.config}
[[ $config_root = /* ]] || die 'XDG_CONFIG_HOME must be an absolute path.'
config_file=$config_root/pacman/makepkg.conf
if [[ ! -e $config_file && ! -L $config_file ]]; then
  if [[ -e $HOME/.makepkg.conf || -L $HOME/.makepkg.conf ]]; then
    config_file=$HOME/.makepkg.conf
  fi
fi

# -----------------------------------------------------------------------------
# Edit bytes without sourcing arbitrary configuration. Preserve unrelated text.
# Python provides exact block removal, backups, and atomic file replacement.
# -----------------------------------------------------------------------------
python3 - "$config_file" "$action" "$jobs" "$lifetime" "$duration" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

path = Path(sys.argv[1]).resolve()
action, jobs, lifetime, duration = sys.argv[2:]
begin = b'\n# BEGIN yay-build-speed managed settings\n'
end = b'# END yay-build-speed managed settings\n'
old = path.read_bytes() if path.exists() else b''

if old.count(begin) != old.count(end) or old.count(begin) > 1:
  sys.exit('Error: damaged or duplicate managed markers; inspect the file.')

start = old.find(begin)
stop = old.find(end)
if start >= 0 and stop < start:
  sys.exit('Error: managed markers are out of order; inspect the file.')

block = old[start:stop + len(end)] if start >= 0 else b''
base = old.replace(block, b'', 1) if block else old
print(f'Configuration: {path}')

if action == 'status':
  print(block.decode() if block else 'No overrides from this script.')
  sys.exit(0)

new = base
if action == 'apply':
  count = '"$(nproc)"' if jobs == 'all' else jobs
  settings = (
    f'BUILDENV+=(\'!check\')\n'
    f'NPROC={count}\n'
    f'MAKEFLAGS="-j${{NPROC}}"\n'
    f'export CMAKE_BUILD_PARALLEL_LEVEL="$NPROC"\n'
    f'export CARGO_BUILD_JOBS="$NPROC"\n'
  ).encode()
  if lifetime != 'permanent':
    boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    condition = (
      '[[ "$(cat /proc/sys/kernel/random/boot_id)" = "' + boot + '" ]]'
    )
    if lifetime == 'timed':
      units = {'s': 1, 'm': 60, 'h': 3600, 'd': 86400}
      seconds = int(duration[:-1]) * units[duration[-1]]
      deadline = int(time.time()) + seconds
      condition += f' && (( $(date +%s) < {deadline} ))'
    settings = (
      f'# Lifetime: {lifetime}; duration: {duration}\n'
      f'if {condition}; then\n'
    ).encode() + b''.join(b'  ' + line for line in settings.splitlines(True))
    settings += b'fi\n'
  new += begin + settings + end

if new == old:
  print('Already in the requested state.')
  sys.exit(0)

path.parent.mkdir(parents=True, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix='.makepkg.conf.', dir=path.parent)
try:
  with os.fdopen(fd, 'wb') as stream:
    stream.write(new)
  # Syntax check only: never execute the user's configuration here.
  subprocess.run(['bash', '-n', temporary], check=True)
  if path.exists():
    backup_fd, backup = tempfile.mkstemp(
      prefix=path.name + '.backup-', dir=path.parent
    )
    os.close(backup_fd)
    shutil.copy2(path, backup)
    shutil.copymode(path, temporary)
    print(f'Backup: {backup}')
  os.replace(temporary, path)
finally:
  if os.path.exists(temporary):
    os.unlink(temporary)

if action == 'apply':
  label = 'all available CPUs' if jobs == 'all' else f'{jobs} jobs'
  print(f'Applied: {label}; check() disabled; lifetime: {lifetime}.')
  print('Effective on the next build. Previous settings apply after expiry.')
else:
  print('Removed managed overrides. Your previous settings now apply.')
  print('Earlier !check entries or saved yay --nocheck flags still apply.')
PY
