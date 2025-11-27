#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# edge-harden-linux.sh — Hardening baseline for Microsoft Edge on Linux
# ─────────────────────────────────────────────────────────────────────────────
# Actions (idempotent, reproducible):
#   - Create /etc/opt/edge/policies/managed/policies.json
#     • Disable MS account sign-in and sync
#     • Minimize diagnostic data / telemetry / personalization
#     • Disable background mode and built-in card/address autofill
#   - Create ~/.config/microsoft-edge-stable-flags.conf
#     • Extra diagnostic-data off switch
#     • Simple password-store setting
#   - Create /usr/local/bin/edge-sandbox (if firejail is available)
#     • Launch Edge inside Firejail with same flags/policies
#
# Design:
#   • Run with sudo: script uses SUDO_USER to target your user’s $HOME.
#   • Existing files are backed up with a timestamp suffix before overwrite.
#
# Usage:
#   sudo ./edge-harden-linux.sh --apply   (default)
#   sudo ./edge-harden-linux.sh --dry-run
#   ./edge-harden-linux.sh --help
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_NAME="${0##*/}"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

function usage() {
  local pager
  pager="${HELP_PAGER:-less -R}"
  if ! command -v less >/dev/null 2>&1; then
    pager="cat"
  fi

  "$pager" <<'EOF'
edge-harden-linux.sh — Harden Microsoft Edge on Linux (policies + flags)

Usage:
  sudo ./edge-harden-linux.sh [--apply] [--dry-run]
  ./edge-harden-linux.sh --help

Options:
  --apply     Apply hardening (default if no option is given).
  --dry-run   Show what would be done, but do not modify anything.
  --help      Show this help text.

What this script does:
  1. Detect Edge binary:
       microsoft-edge-stable  or  microsoft-edge

  2. System policies (requires root):
       /etc/opt/edge/policies/managed/policies.json

     Written JSON disables:
       - Browser sign-in with Microsoft account
       - Cloud sync
       - Most diagnostic / telemetry reporting
       - Personalisation reporting
       - Background mode
       - Address and credit-card autofill

     A backup is created if a policy file already exists, e.g.:
       policies.json.bak-20251127-123456

  3. Per-user flags (for the sudo caller, not root):
       ~/.config/microsoft-edge-stable-flags.conf

     Flags added:
       --enable-features=msDiagnosticDataForceOff
       --password-store=basic

     A backup is created if the file already exists.

  4. Firejail launcher (if firejail is installed):
       /usr/local/bin/edge-sandbox

     Simple wrapper:
       firejail microsoft-edge-stable "$@"

     This lets you start Edge inside a system-level sandbox:
       edge-sandbox

Reverting:
  - Remove or edit:
       /etc/opt/edge/policies/managed/policies.json
       ~/.config/microsoft-edge-stable-flags.conf
       /usr/local/bin/edge-sandbox
  - Or restore from the *.bak-YYYYmmdd-HHMMSS backups created by this script.
EOF
}

function timestamp() {
  date +"%Y%m%d-%H%M%S"
}

function info() {
  printf '[INFO] %s\n' "$*" >&2
}

function warn() {
  printf '[WARN] %s\n' "$*" >&2
}

function die() {
  printf '[ERR ] %s\n' "$*" >&2
  exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────

ACTION="apply"

for arg in "${@:-}"; do
  case "$arg" in
  --help | -h)
    usage
    exit 0
    ;;
  --apply)
    ACTION="apply"
    ;;
  --dry-run)
    ACTION="dry-run"
    ;;
  *)
    die "Unknown option: $arg (use --help)"
    ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Environment / user detection
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$(id -u)" -ne 0 ]]; then
  if [[ "$ACTION" == "dry-run" ]]; then
    warn "Not running as root; dry-run is still fine."
  else
    die "Please run with sudo (system policy paths require root)."
  fi
fi

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(eval echo "~${TARGET_USER}")"

if [[ ! -d "$TARGET_HOME" ]]; then
  die "Could not resolve home for user '${TARGET_USER}'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Detect Edge binary
# ─────────────────────────────────────────────────────────────────────────────

EDGE_BIN=""
for candidate in "microsoft-edge-stable" "microsoft-edge"; do
  if command -v "$candidate" >/dev/null 2>&1; then
    EDGE_BIN="$candidate"
    break
  fi
done

if [[ -z "$EDGE_BIN" ]]; then
  die "Could not find microsoft-edge-stable or microsoft-edge in PATH."
fi

info "Using Edge binary: $EDGE_BIN"

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

POLICY_DIR="/etc/opt/edge/policies/managed"
POLICY_FILE="${POLICY_DIR}/policies.json"
USER_CONFIG_DIR="${TARGET_HOME}/.config"
FLAGS_FILE="${USER_CONFIG_DIR}/microsoft-edge-stable-flags.conf"
FIREJAIL_WRAPPER="/usr/local/bin/edge-sandbox"

# ─────────────────────────────────────────────────────────────────────────────
# Write system policy JSON
# ─────────────────────────────────────────────────────────────────────────────

function apply_policies() {
  info "Preparing system policy file at: ${POLICY_FILE}"

  if [[ -f "$POLICY_FILE" ]]; then
    local bak="${POLICY_FILE}.bak-$(timestamp)"
    info "Existing policies.json found; backing up to: ${bak}"
    cp -a -- "$POLICY_FILE" "$bak"
  fi

  mkdir -p "$POLICY_DIR"

  cat >"$POLICY_FILE" <<'EOF'
{
  "BrowserSignin": 0,
  "SyncDisabled": true,
  "DiagnosticData": 0,
  "MetricsReportingEnabled": false,
  "PersonalizationReportingEnabled": false,
  "Edge3PSerpTelemetryEnabled": false,
  "BackgroundModeEnabled": false,
  "AutofillAddressEnabled": false,
  "AutofillCreditCardEnabled": false
}
EOF

  info "Wrote hardened Edge policy JSON."
  info "You can inspect policies at: edge://policy"
}

# ─────────────────────────────────────────────────────────────────────────────
# Write per-user flags file
# ─────────────────────────────────────────────────────────────────────────────

function apply_flags() {
  info "Preparing flags file for user ${TARGET_USER}: ${FLAGS_FILE}"

  install -d -m 0755 -- "$USER_CONFIG_DIR"

  if [[ -f "$FLAGS_FILE" ]]; then
    local bak="${FLAGS_FILE}.bak-$(timestamp)"
    info "Existing flags file found; backing up to: ${bak}"
    cp -a -- "$FLAGS_FILE" "$bak"
  fi

  cat >"$FLAGS_FILE" <<'EOF'
# Extra command-line flags for Microsoft Edge (Linux).
# This file is read by the Edge launcher script and appended at startup.
#
# Adjust as needed. Lines beginning with "#" are comments.
#
# Privacy / telemetry hardening:
--enable-features=msDiagnosticDataForceOff

# Password store:
#  - "basic": Edge keeps its own encrypted DB.
#  - You probably want an external password manager for serious use.
--password-store=basic
EOF

  chown "${TARGET_USER}:${TARGET_USER}" "$FLAGS_FILE"
  info "Wrote per-user Edge flags file."
}

# ─────────────────────────────────────────────────────────────────────────────
# Optional Firejail wrapper
# ─────────────────────────────────────────────────────────────────────────────

function apply_firejail_wrapper() {
  if ! command -v firejail >/dev/null 2>&1; then
    warn "firejail not found; skipping edge-sandbox wrapper."
    return 0
  fi

  info "Creating Firejail wrapper: ${FIREJAIL_WRAPPER}"

  if [[ -f "$FIREJAIL_WRAPPER" ]]; then
    local bak="${FIREJAIL_WRAPPER}.bak-$(timestamp)"
    info "Existing wrapper found; backing up to: ${bak}"
    cp -a -- "$FIREJAIL_WRAPPER" "$bak"
  fi

  cat >"$FIREJAIL_WRAPPER" <<EOF
#!/usr/bin/env bash
# edge-sandbox — launch Edge inside Firejail
exec firejail --quiet "${EDGE_BIN}" "\$@"
EOF

  chmod 0755 "$FIREJAIL_WRAPPER"
  info "You can now run Edge inside Firejail via: edge-sandbox"
}

# ─────────────────────────────────────────────────────────────────────────────
# Dry-run reporting
# ─────────────────────────────────────────────────────────────────────────────

function dry_run_report() {
  cat <<EOF
[DRY-RUN] Would target user:        ${TARGET_USER}
[DRY-RUN] With home directory:      ${TARGET_HOME}
[DRY-RUN] Edge binary detected:     ${EDGE_BIN}

[DRY-RUN] System policy path:
  ${POLICY_FILE}

[DRY-RUN] Per-user flags file:
  ${FLAGS_FILE}

[DRY-RUN] Firejail wrapper (if firejail exists):
  ${FIREJAIL_WRAPPER}

No files were modified. Re-run with:
  sudo ./${SCRIPT_NAME} --apply
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

case "$ACTION" in
apply)
  apply_policies
  apply_flags
  apply_firejail_wrapper
  info "Done. Restart Edge to apply policies and flags."
  ;;
dry-run)
  dry_run_report
  ;;
*)
  die "Internal error: unknown ACTION=${ACTION}"
  ;;
esac
