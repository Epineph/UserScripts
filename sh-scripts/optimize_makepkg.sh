#!/usr/bin/env bash
###################################################################
# mkpkg-speedup — enforce “fast, no-tests” builds system-wide
#                  and per-user, plus optional priority wrapper
#
# Usage:
#   sudo ./makepkg_conf_v2.sh [--with-wrapper] [--help]
#
# Options:
#   --with-wrapper   Install ~/bin/makepkg wrapper that runs
#                     makepkg under ionice + nice (if available).
#   --help           Show this help and exit.
#
# What it does:
#  1. Writes (with backup) /etc/makepkg.conf.d/99-speed.conf
#     and ~/.makepkg.conf with:
#       • MAKEFLAGS="-j$(nproc)"           # parallel builds
#       • BUILDENV=(!color !check !sign)   # allow ccache & distcc
#       • COMPRESSXZ=(xz -c -z - --threads=0)
#       • COMPRESSZST=(zstd -c -T0 -)       # fast multi-threaded zstd
#  2. Optional: creates ~/bin/makepkg wrapper to boost priority
#  3. If run as root and cpupower is installed, switches
#     CPU governor to “performance”
###################################################################
set -euo pipefail
IFS=$'\n\t'

# ──────────────────────────────────────────────────────────────────
#  Constants & Helpers
# ──────────────────────────────────────────────────────────────────
SYS_DIR="/etc/makepkg.conf.d"
SYS_FILE="${SYS_DIR}/99-speed.conf"
USR_FILE="${HOME}/.makepkg.conf"
TIMESTAMP() { date +%Y%m%dT%H%M%S; }

# Desired content of both system and user config
read -r -d '' DESIRED_CONTENT <<'EOF'
# parallel builds
MAKEFLAGS="-j$(nproc)"

# allow ccache & distcc wrappers, but disable color/check/sign stages
BUILDENV=(!color !check !sign)

# parallel compression settings
COMPRESSXZ=(xz -c -z - --threads=0)
COMPRESSZST=(zstd -c -T0 -)
EOF

# Backup function: copy to .bak-<timestamp> if it exists
backup_if_exists() {
  local file="$1"
  if [[ -e "$file" ]]; then
    cp -a -- "$file" "${file}.bak-$(TIMESTAMP)"
    echo "• backed up $file → ${file}.bak-$(TIMESTAMP)"
  fi
}

# Write out the config file (with backup)
write_config() {
  local target="$1"
  backup_if_exists "$target"
  printf '%s\n' "$DESIRED_CONTENT" > "$target"
  echo "• wrote $target"
}

# Show help
show_help() {
  sed -n '1,12p' "$0" | sed 's/^# //'
}

# ──────────────────────────────────────────────────────────────────
#  Parse options
# ──────────────────────────────────────────────────────────────────
INSTALL_WRAPPER=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-wrapper) INSTALL_WRAPPER=true; shift ;;
    --help) show_help; exit 0 ;;
    *) echo "Unknown option: $1" >&2; show_help; exit 1 ;;
  esac
done

# ──────────────────────────────────────────────────────────────────
#  1) Per-user config
# ──────────────────────────────────────────────────────────────────
write_config "$USR_FILE"

# ──────────────────────────────────────────────────────────────────
#  2) System-wide config (requires root)
# ──────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "• not root → skipping $SYS_FILE (re-run under sudo to apply system-wide)"
else
  mkdir -p "$SYS_DIR"
  write_config "$SYS_FILE"
  echo "✓ system-wide override active immediately"
fi

# ──────────────────────────────────────────────────────────────────
#  3) Optional: makepkg wrapper for ionice + nice
# ──────────────────────────────────────────────────────────────────
if [[ "$INSTALL_WRAPPER" == true ]]; then
  # Ensure ~/bin is early in PATH
  mkdir -p "$HOME/bin"
  if ! grep -q ':\$HOME/bin:' <<<":$PATH:"; then
    echo "export PATH=\"\$HOME/bin:\$PATH\"" >> "$HOME/.profile"
    echo "• added ~/bin to PATH in ~/.profile"
  fi

  WRAPPER="$HOME/bin/makepkg"
  backup_if_exists "$WRAPPER"
  cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
# Wrapper to run makepkg under ionice & nice for faster responsiveness
# Detect ionice availability
if command -v ionice &>/dev/null; then
  IONICE_CMD=(ionice -c2 -n0)
else
  IONICE_CMD=()
fi
# Use higher CPU priority if available
NICE_CMD=(nice -n -5)

# Execute
exec "${IONICE_CMD[@]}" "${NICE_CMD[@]}" /usr/bin/makepkg "$@"
EOF
  chmod +x "$WRAPPER"
  echo "• installed makepkg wrapper at $WRAPPER"
fi

# ──────────────────────────────────────────────────────────────────
#  4) Optional: switch CPU governor to performance (root only)
# ──────────────────────────────────────────────────────────────────
if [[ $EUID -eq 0 ]] && command -v cpupower &>/dev/null; then
  echo "• setting CPU governor → performance"
  cpupower frequency-set -g performance
fi

echo "Done."
exit 0

