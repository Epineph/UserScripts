#!/usr/bin/env bash
#
# generate_mkinitcpio.sh
# Backs up current mkinitcpio.conf and installs an AMD-tuned version

set -euo pipefail

TARGET="/etc/mkinitcpio.conf"
BACKUP="${TARGET}.bak.$(date +%Y%m%d%H%M%S)"

echo "Backing up existing config to ${BACKUP}…"
sudo cp "${TARGET}" "${BACKUP}"

echo "Installing new mkinitcpio.conf…"
sudo tee "${TARGET}" > /dev/null << 'EOF'
# /etc/mkinitcpio.conf
# vim:set ft=sh
#
# Optimized for AMD Ryzen + Radeon (amdgpu), LVM2 root, systemd-initramfs
# Key changes:
#  • Use systemd hook and remove udev to avoid duplication
#  • Place microcode early so CPU firmware updates load first
#  • sd-vconsole for console font/keymap under systemd
#  • autodetect for most modules; pin only amdgpu manually
#  • zstd compression for speed & size

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
  microcode       # CPU microcode updates before autodetect
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

