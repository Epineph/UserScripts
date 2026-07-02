#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# locale-setup — Apply or revert system-wide locale settings (Arch/systemd)
# -----------------------------------------------------------------------------
# Policy written to /etc/locale.conf:
#   LANG=en_DK.UTF-8
#   LC_COLLATE=C
#   LC_TIME=en_DK.UTF-8
#   LC_NUMERIC=en_DK.UTF-8
#   LC_MONETARY=en_DK.UTF-8
#   LC_PAPER=en_DK.UTF-8
#   LC_MEASUREMENT=en_DK.UTF-8
#
# Also ensures /etc/locale.gen contains:
#   en_DK.UTF-8 UTF-8
#   en_US.UTF-8 UTF-8
#
# Actions:
#   apply     (default) — write files, run locale-gen (idempotent)
#   dry-run              — print intended changes, do nothing
#   show                — print current file contents and status
#   revert              — restore from latest backups if found
#
# Backups are placed as:
#   /etc/locale.gen.bak.YYYY-MM-DD
#   /etc/locale.conf.bak.YYYY-MM-DD
# and also copied to: /home/heini/.log/backups/
#
# Notes:
# - Requires root. We do NOT set LC_ALL globally.
# - Use: LC_ALL=C.UTF-8 LANG=C.UTF-8 yay -S <pkg>  for one-off builds.
# -----------------------------------------------------------------------------

set -euo pipefail

DATE="$(date +%F)"
GEN="/etc/locale.gen"
CONF="/etc/locale.conf"
GEN_BAK="$GEN.bak.$DATE"
CONF_BAK="$CONF.bak.$DATE"

LOG_DIR="/home/heini/.log"
BK_DIR="$LOG_DIR/backups"
LOG_FILE="$LOG_DIR/locale-setup.log"

USE_LOCALCTL=0
ACTION="apply"

LANG_VAL="en_DK.UTF-8"
LC_COLLATE_VAL="C"
LC_OTHER_VAL="en_DK.UTF-8"
ENABLE_LOCALES=("en_DK.UTF-8 UTF-8" "en_US.UTF-8 UTF-8")

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
function usage() {
  cat <<'EOF'
locale-setup — apply or revert system-wide locale settings

Synopsis
  sudo locale-setup [apply|dry-run|show|revert] [--use-localectl]

Description
  apply      Write /etc/locale.conf, ensure /etc/locale.gen entries, run
             locale-gen. Create backups and logs. (Default action.)
  dry-run    Show intended edits without changing anything.
  show       Print current files and runtime status.
  revert     Restore from today's backups if present.

Options
  --use-localectl  Also call 'localectl set-locale …' after writing files.

Policy written to /etc/locale.conf:
  LANG=en_DK.UTF-8
  LC_COLLATE=C
  LC_TIME=en_DK.UTF-8
  LC_NUMERIC=en_DK.UTF-8
  LC_MONETARY=en_DK.UTF-8
  LC_PAPER=en_DK.UTF-8
  LC_MEASUREMENT=en_DK.UTF-8
EOF
}

function need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "error: please run as root" >&2
    exit 1
  fi
}

function log() {
  mkdir -p "$LOG_DIR" "$BK_DIR"
  printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG_FILE"
}

function backup_files() {
  [[ -f "$GEN"  ]] && cp -a "$GEN"  "$GEN_BAK"  && log "backup $GEN -> $GEN_BAK"
  [[ -f "$CONF" ]] && cp -a "$CONF" "$CONF_BAK" && log "backup $CONF -> $CONF_BAK"
  # Also copy to user-visible backup dir
  [[ -f "$GEN_BAK"  ]] && cp -a "$GEN_BAK"  "$BK_DIR/" && log "copy $GEN_BAK -> $BK_DIR/"
  [[ -f "$CONF_BAK" ]] && cp -a "$CONF_BAK" "$BK_DIR/" && log "copy $CONF_BAK -> $BK_DIR/"
}

function enable_locales_in_gen() {
  # Ensure desired lines exist and are uncommented.
  touch "$GEN"
  for loc in "${ENABLE_LOCALES[@]}"; do
    # Uncomment if present commented.
    sed -i -E "s|^#\s*(${loc//./\\.})|\1|" "$GEN"
    # Append if missing.
    if ! grep -q -E "^\s*${loc//./\\.}\s*$" "$GEN"; then
      echo "$loc" >>"$GEN"
      log "add '$loc' to $GEN"
    fi
  done
}

function write_locale_conf() {
  cat >"$CONF" <<EOF
LANG=$LANG_VAL
LC_COLLATE=$LC_COLLATE_VAL
LC_TIME=$LC_OTHER_VAL
LC_NUMERIC=$LC_OTHER_VAL
LC_MONETARY=$LC_OTHER_VAL
LC_PAPER=$LC_OTHER_VAL
LC_MEASUREMENT=$LC_OTHER_VAL
EOF
  log "wrote $CONF"
}

function do_apply() {
  need_root
  mkdir -p "$LOG_DIR" "$BK_DIR"
  log "action=apply"
  backup_files
  enable_locales_in_gen
  echo "Running locale-gen ..."
  locale-gen | tee -a "$LOG_FILE"
  write_locale_conf
  if [[ $USE_LOCALCTL -eq 1 ]] && command -v localectl >/dev/null 2>&1; then
    echo "Calling localectl set-locale ..."
    localectl set-locale \
      LANG="$LANG_VAL" \
      LC_COLLATE="$LC_COLLATE_VAL" \
      LC_TIME="$LC_OTHER_VAL" \
      LC_NUMERIC="$LC_OTHER_VAL" \
      LC_MONETARY="$LC_OTHER_VAL" \
      LC_PAPER="$LC_OTHER_VAL" \
      LC_MEASUREMENT="$LC_OTHER_VAL" | tee -a "$LOG_FILE"
    log "localectl set-locale applied"
  fi
  echo "Done. Re-log or reboot for all sessions to pick up new locale."
}

function do_dry_run() {
  echo "[dry-run] Would back up to:"
  echo "  $GEN_BAK"
  echo "  $CONF_BAK"
  echo
  echo "[dry-run] Would ensure these lines in $GEN:"
  for loc in "${ENABLE_LOCALES[@]}"; do echo "  $loc"; done
  echo
  echo "[dry-run] Would write $CONF with:"
  cat <<EOF
LANG=$LANG_VAL
LC_COLLATE=$LC_COLLATE_VAL
LC_TIME=$LC_OTHER_VAL
LC_NUMERIC=$LC_OTHER_VAL
LC_MONETARY=$LC_OTHER_VAL
LC_PAPER=$LC_OTHER_VAL
LC_MEASUREMENT=$LC_OTHER_VAL
EOF
  [[ $USE_LOCALCTL -eq 1 ]] && echo "[dry-run] Would run: localectl set-locale …"
}

function latest_backup_of() {
  # Return latest backup path for given file or empty string.
  ls -1t "$1".bak.* 2>/dev/null | head -n1 || true
}

function do_revert() {
  need_root
  log "action=revert"
  local gen_last conf_last did=0
  gen_last="$(latest_backup_of "$GEN")"
  conf_last="$(latest_backup_of "$CONF")"
  if [[ -n "$gen_last" && -f "$gen_last" ]]; then
    cp -a "$gen_last" "$GEN"
    echo "Restored $GEN from $gen_last"
    log "restore $GEN <- $gen_last"
    did=1
  else
    echo "No backup found for $GEN"
  fi
  if [[ -n "$conf_last" && -f "$conf_last" ]]; then
    cp -a "$conf_last" "$CONF"
    echo "Restored $CONF from $conf_last"
    log "restore $CONF <- $conf_last"
    did=1
  else
    echo "No backup found for $CONF"
  fi
  if [[ $did -eq 0 ]]; then
    echo "Nothing restored (no backups found)."
    exit 1
  fi
  echo "Reverted. Consider running: locale-gen"
}

function do_show() {
  echo "----- $GEN -----"
  if [[ -f "$GEN" ]]; then
    grep -E '^(en_DK\.UTF-8|en_US\.UTF-8)' "$GEN" || true
  else
    echo "(missing)"
  fi
  echo
  echo "----- $CONF -----"
  if [[ -f "$CONF" ]]; then
    cat "$CONF"
  else
    echo "(missing)"
  fi
  echo
  echo "----- locale -a (filtered) -----"
  locale -a | grep -E 'en_DK\.UTF-8|en_US\.UTF-8' || true
  echo
  echo "----- localectl status -----"
  if command -v localectl >/dev/null 2>&1; then
    localectl status
  else
    echo "(localectl not available)"
  fi
  echo
  echo "----- current session: locale -----"
  locale
  echo
  echo "Log file: $LOG_FILE"
}

# -----------------------------------------------------------------------------
# Arg parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    apply|dry-run|show|revert) ACTION="$1"; shift;;
    --use-localectl) USE_LOCALCTL=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $1"; usage; exit 2;;
  esac
done

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
case "$ACTION" in
  apply)    do_apply;;
  dry-run)  do_dry_run;;
  show)     do_show;;
  revert)   do_revert;;
esac
