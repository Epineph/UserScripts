#!/usr/bin/env bash
###############################################################################
# mkpkg-speedup.sh — configure per-user makepkg to skip tests and build fast
#
# USAGE
#   ./mkpkg-speedup.sh          # one-shot; asks before touching the file
#
# WHAT IT DOES
#   • Creates  ~/.makepkg.conf  if it does not exist.
#   • Ensures the following assignments are present exactly once:
#       MAKEFLAGS="-j<N>"         # N = number of online cores (nproc)
#       BUILDENV=(!distcc !color !ccache !check !sign)
#   • Backs up an existing file to ~/.makepkg.conf.bak-<timestamp>
#
# EXIT CODES
#   0  success   – configuration is now active
#   1  unhandled – could not create a backup or write the file
#
# NOTES
#   * makepkg(5) is a plain Bash script; the config file is *sourced*,
#     therefore $(nproc) is evaluated **every time you build** :contentReference[oaicite:0]{index=0}
#   * The !check token in BUILDENV disables the test suite :contentReference[oaicite:1]{index=1}
###############################################################################

set -euo pipefail

#------------------------------------------------------------------------
CONFIG_FILE="${HOME}/.makepkg.conf"
CORES="$(nproc)"

# Desired lines (use printf to avoid escape-hell)
MAKEFLAGS_LINE=$(printf 'MAKEFLAGS="-j%s"' "$CORES")
BUILDENV_LINE='BUILDENV=(!distcc !color !ccache !check !sign)'

#------------------------------------------------------------------------
backup() {
  local ts backup_file
  ts="$(date +%Y%m%dT%H%M%S)"
  backup_file="${CONFIG_FILE}.bak-${ts}"
  cp -a -- "$CONFIG_FILE" "$backup_file"
  echo "• Backed up existing config to $backup_file"
}

write_config() {
  printf '%s\n%s\n' "$MAKEFLAGS_LINE" "$BUILDENV_LINE" > "$CONFIG_FILE"
}

update_config() {
  # Strip any existing definitions and append the fresh ones
  sed -i -E '/^MAKEFLAGS=.*$/d;/^BUILDENV=.*$/d' "$CONFIG_FILE"
  {
    echo "$MAKEFLAGS_LINE"
    echo "$BUILDENV_LINE"
  } >> "$CONFIG_FILE"
}

echo ">>> Preparing to enforce fast, test-free builds in $CONFIG_FILE"
if [[ -f "$CONFIG_FILE" ]]; then
  read -rp "File exists — overwrite the two settings? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
  backup
  update_config
else
  write_config
fi

echo "✓ Done. New settings are active immediately."
exit 0

