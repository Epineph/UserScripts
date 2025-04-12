#!/usr/bin/env bash
#==============================================================================
# fix_key_perms.sh
#
# Script to enforce correct ownership & permissions for .ssh and .gnupg
# directories/files. Useful for preventing accidental exposures or SSH rejections
# caused by improper file modes.
#
# Usage: fix_key_perms.sh [username]
#  - If username is not provided, the script defaults to the current user.
#
# Author:   You (based on best practices)
# License:  Public Domain / MIT
#==============================================================================

set -euo pipefail

# Determine which user to fix
TARGET_USER="${1:-$(id -un)}"
TARGET_HOME="$(eval echo "~${TARGET_USER}")"

# Validate that we found a real home directory
if [[ ! -d "$TARGET_HOME" ]]; then
  echo "Error: Home directory for user '$TARGET_USER' not found at '$TARGET_HOME'." >&2
  exit 1
fi

# If running as root, set ownership; if not, we can only fix perms, not owners
IS_ROOT=false
if [[ $EUID -eq 0 ]]; then
  IS_ROOT=true
fi

echo "Fixing permissions for user: $TARGET_USER"
echo "Home directory: $TARGET_HOME"
echo

# ------------------------------------------------------------------------------
# 1) Fix SSH Directory and Files
# ------------------------------------------------------------------------------

SSH_DIR="$TARGET_HOME/.ssh"
if [[ -d "$SSH_DIR" ]]; then
  echo "==> .ssh directory found at $SSH_DIR"
  
  # (Optional) Ensure correct ownership if script is run as root
  if $IS_ROOT; then
    chown -R "$TARGET_USER:$TARGET_USER" "$SSH_DIR"
  fi

  # Directory must be 700
  chmod 700 "$SSH_DIR"

  # Common private key filenames
  for privkey in id_rsa id_ecdsa id_ed25519 id_dsa; do
    if [[ -f "$SSH_DIR/$privkey" ]]; then
      chmod 600 "$SSH_DIR/$privkey"
    fi
  done

  # Public keys
  for pubkey in id_rsa.pub id_ecdsa.pub id_ed25519.pub id_dsa.pub; do
    if [[ -f "$SSH_DIR/$pubkey" ]]; then
      chmod 644 "$SSH_DIR/$pubkey"
    fi
  done

  # authorized_keys - typically 600 (though some allow 644)
  if [[ -f "$SSH_DIR/authorized_keys" ]]; then
    chmod 600 "$SSH_DIR/authorized_keys"
  fi

  # known_hosts - 644 is typical, 600 also fine
  if [[ -f "$SSH_DIR/known_hosts" ]]; then
    chmod 644 "$SSH_DIR/known_hosts"
  fi

  # SSH config
  if [[ -f "$SSH_DIR/config" ]]; then
    chmod 600 "$SSH_DIR/config"
  fi

  echo "SSH permissions corrected."
  echo
else
  echo "No .ssh directory found at $SSH_DIR, skipping SSH fixes."
  echo
fi

# ------------------------------------------------------------------------------
# 2) Fix GnuPG Directory and Files
# ------------------------------------------------------------------------------

GNUPG_DIR="$TARGET_HOME/.gnupg"
if [[ -d "$GNUPG_DIR" ]]; then
  echo "==> .gnupg directory found at $GNUPG_DIR"

  # Ensure correct ownership if root
  if $IS_ROOT; then
    chown -R "$TARGET_USER:$TARGET_USER" "$GNUPG_DIR"
  fi

  # GnuPG directory must be 700
  chmod 700 "$GNUPG_DIR"

  # Subdirectories often contain private key data
  find "$GNUPG_DIR" -mindepth 1 -type d -exec chmod 700 {} \;

  # Common GnuPG files
  # Private keys, trustdb, config, etc. => 600
  for file in pubring.kbx trustdb.gpg gpg.conf gpg-agent.conf; do
    if [[ -f "$GNUPG_DIR/$file" ]]; then
      chmod 600 "$GNUPG_DIR/$file"
    fi
  done

  # If you keep 'private-keys-v1.d/' subdirectory
  if [[ -d "$GNUPG_DIR/private-keys-v1.d" ]]; then
    chmod 700 "$GNUPG_DIR/private-keys-v1.d"
    find "$GNUPG_DIR/private-keys-v1.d" -type f -exec chmod 600 {} \;
  fi

  echo "GnuPG permissions corrected."
  echo
else
  echo "No .gnupg directory found at $GNUPG_DIR, skipping GnuPG fixes."
  echo
fi

echo "All done! Checked and (where applicable) fixed ownership & permissions."
exit 0
