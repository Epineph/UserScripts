#!/usr/bin/env bash
###############################################################################
# mkpkg-speedup — enforce “fast, no-tests” builds system-wide and per-user
#
# * Writes /etc/makepkg.conf.d/99-speed.conf     (root, overrides distro file)
# * Writes ~/.makepkg.conf                       (user, overrides all system files)
#   Both files contain:
#       MAKEFLAGS="-j$(nproc)"                   # dynamic core count
#       BUILDENV=(!distcc !color !ccache !check !sign)
#
# * Backs up any existing target to *.bak-<timestamp>
# * Idempotent: you can run it again after a pacman update drops a .pacnew
# * Needs sudo for the system drop-in, falls back gracefully if not root.
#
# Exit codes: 0 success | 1 any failure
###############################################################################
set -euo pipefail

#----------------------------------------------------------- constants & helpers
SYS_DIR="/etc/makepkg.conf.d"
SYS_FILE="${SYS_DIR}/99-speed.conf"          # drop-in beats /etc/makepkg.conf :contentReference[oaicite:0]{index=0}
USR_FILE="${HOME}/.makepkg.conf"

desired_content='MAKEFLAGS="-j$(nproc)"
BUILDENV=(!distcc !color !ccache !check !sign)'

timestamp() { date +%Y%m%dT%H%M%S; }

backup_if_exists() {
  local f=$1
  [[ -e "$f" ]] && cp -a -- "$f" "${f}.bak-$(timestamp)"
}

write_file() {
  local target=$1
  backup_if_exists "$target"
  printf '%s\n' "$desired_content" > "$target"
  echo "• wrote $target"
}

#----------------------------------------------------------- per-user section
write_file "$USR_FILE"

#----------------------------------------------------------- system-wide section
if [[ $EUID -ne 0 ]]; then
  echo "• not root → skipping ${SYS_FILE}; re-run under sudo if you want the system drop-in"
else
  mkdir -p "$SYS_DIR"
  write_file "$SYS_FILE"
  echo "✓ system-wide override active immediately (makepkg sources *.conf every run) :contentReference[oaicite:1]{index=1}"
fi

exit 0

