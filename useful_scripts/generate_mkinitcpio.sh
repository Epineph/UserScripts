#!/usr/bin/env bash
#
# generate_mkinitcpio.sh
# Backs up current mkinitcpio.conf and installs an AMD-tuned v# iersion

set -euo pipefail

TARGET="/etc/mkinitcpio.conf"
BACKUP="${TARGET}.bak.$(date +%Y%m%d%H%M%S)"


# ── MODULES ───────────────────────────────────
MODULES=(amdgpu)

# ── BINARIES ──────────────────────────────────
BINARIES=()

# ── FILES ─────────────────────────────────────
FILES=()

# ── HOOKS ─────────────────────────────────────
HOOKS=(
  base            # core init scripts
  systemd         # systemd as init (replaces udev)
  microcode       # CPU microcode updates before aut                            # odetect
  autodetect      # auto-include necessary modules
  modconf         # parse /etc/modprobe.d
  sd-vconsole     # consolefont & keymap via systemd
  block           # disk & LVM setup
  lvm2            # activate LVM2 volumes
  filesystems     # mount filesystems
  fsck            # filesystem checks
)

# ── COMPRESSION ───────────────────────────────
COMPRESSION="zstd"
COMPRESSION_OPTIONS=("--fast")

# ── MODULES_DECOMPRESS ───────────────────────
#MODULES_DECOMPRESS="no"
EOF

echo "Done. You can now rebuild your initramfs with:"
echo "  sudo mkinitcpio -P"
echo "Then reboot to apply the new configuration."


# ── COMPRESSION ───────────────────────────────
COMPRESSION="zstd"
COMPRESSION_OPTIONS=("--fast")

# ── MODULES_DECOMPRESS ───────────────────────
#MODULES_DECOMPRESS="no"
EOF

echo "Done. You can now rebuild your initramfs with:"
echo "  sudo mkinitcpio -P"
echo "Then reboot to apply the new configuration."


HOOKS=(
  base            # core init scripts
  systemd         # systemd as init (replaces udev)
  microcode       # CPU microcode updates before aut                  # odetect
  autodetect      # auto-include necessary modules
  modconf         # parse /etc/modprobe.d
  sd-vconsole     # consolefont & keymap via systemd
  block           # disk & LVM setup
  lvm2            # activate LVM2 volumes
  filesystems     # mount filesystems
  fsck            # filesystem checks
)

# ── COMPRESSION ───────────────────────────────
COMPRESSION="zstd"
COMPRESSION_OPTIONS=("--fast")

# ── MODULES_DECOMPRESS ───────────────────────
#MODULES_DECOMPRESS="no"
EOF

echo "Done. You can now rebuild your initramfs with:"
echo "  sudo mkinitcpio -P"
echo "Then reboot to apply the new configuration."

