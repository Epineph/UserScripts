#!/usr/bin/env bash
set -Eeuo pipefail

# secure-archive
# Layered archival with per-source 7z encryption, optional outer tar.gz + 7z.
# - Per-source password is prompted interactively by 7z (no exposure in ps or history).
# - Filenames are encrypted (-mhe=on).
# - Sources can be deleted right after their archive is created to save disk space.
# - Optional outer bundle: tar.gz -> then 7z with a separate password.

# ---------- Defaults ----------
DEST_DIR="."
OUTER_FORMAT="none"      # one of: none, tar.gz
REMOVE_INTERMEDIATE=true # remove inner .7z after making outer bundle
PRESERVE_SOURCE=false
CONFIRM=true             # ask before deleting sources
DRY_RUN=false
FORCE=false
LEVEL=9                  # 7z -mx level (1..9)
declare -a SOURCES=()

# ---------- Helpers ----------
abort() { printf 'Error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'USAGE'
secure-archive — Per-folder 7z encryption, optional outer tar.gz + 7z wrapper.

USAGE:
  secure-archive [OPTIONS] -s <path> [-s <path> ...]
  secure-archive [OPTIONS] --source-list "<p1>,<p2>,..."

REQUIRED:
  -s, --source PATH            Source file or directory (repeatable)
      --source-list LIST       Comma-separated sources (alternative to -s)

OPTIONS:
  -d, --destination DIR        Where outputs are written (default: .)
      --outer-format FMT       Outer bundle format: none|tar.gz (default: none)
      --keep-inner             Keep inner .7z files after outer bundle
      --no-confirm             Do not ask before deleting sources
      --preserve-source        Do not delete sources after first-stage archive
      --level N                7z compression level 1..9 (default: 9)
      --dry-run                Show size/free-space plan; do not write outputs
      --force                  Overwrite existing outputs if present
  -h, --help                   This help

BEHAVIOUR:
  1) Each source -> <basename>.7z (AES-256, filenames encrypted). 7z will
     securely prompt for a password for each archive (no echo).
  2) If --preserve-source is NOT set, each source is deleted immediately after
     its .7z is created (unless --no-confirm is given).
  3) If --outer-format tar.gz is set:
       - Create bundle.tar.gz in DEST_DIR from all inner .7z files.
       - Wrap bundle.tar.gz in bundle.tar.gz.7z with its own password prompt.
       - Remove the intermediate bundle.tar.gz.
       - Remove inner .7z unless --keep-inner is specified.

NOTES:
  • Passwords are never shown on the command line or stored in history.
  • For space efficiency, outer tar.gz is written directly to DEST_DIR.
  • If DEST_DIR is a different filesystem, peak space usage is reduced on source fs.

EXAMPLES:
  # Three folders, delete sources after each archive, then outer tar.gz+7z:
  secure-archive -s folder1 -s folder2 -s folder3 -d /usb --outer-format tar.gz

  # Keep sources and inner .7z, no confirmations:
  secure-archive -s data -s notes --preserve-source --keep-inner --no-confirm

  # Dry-run planning (sizes and free space):
  secure-archive --source-list "A,B,C" -d /mnt/backup --outer-format tar.gz --dry-run
USAGE
}

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--source)        [[ $# -ge 2 ]] || abort "Missing value for $1"; SOURCES+=("$2"); shift 2 ;;
    --source-list)      [[ $# -ge 2 ]] || abort "Missing value for $1"; IFS=',' read -r -a tmp <<<"$2"; SOURCES+=("${tmp[@]}"); shift 2 ;;
    -d|--destination)   [[ $# -ge 2 ]] || abort "Missing value for $1"; DEST_DIR="$2"; shift 2 ;;
    --outer-format)     [[ $# -ge 2 ]] || abort "Missing value for $1"; OUTER_FORMAT="$2"; shift 2 ;;
    --keep-inner)       REMOVE_INTERMEDIATE=false; shift ;;
    --no-confirm)       CONFIRM=false; shift ;;
    --preserve-source)  PRESERVE_SOURCE=true; shift ;;
    --level)            [[ $# -ge 2 ]] || abort "Missing value for $1"; LEVEL="$2"; shift 2 ;;
    --dry-run)          DRY_RUN=true; shift ;;
    --force)            FORCE=true; shift ;;
    -h|--help)          usage; exit 0 ;;
    *)                  abort "Unknown option: $1" ;;
  esac
done

[[ ${#SOURCES[@]} -ge 1 ]] || { usage; abort "At least one --source is required."; }

# ---------- Validate env/tools ----------
have 7z  || abort "7z not found. Install p7zip."
have tar || abort "tar not found."
have gzip || abort "gzip not found."
have du  || abort "du not found."
have df  || abort "df not found."

[[ "$OUTER_FORMAT" =~ ^(none|tar\.gz)$ ]] || abort "--outer-format must be: none|tar.gz"
[[ "$LEVEL" =~ ^[1-9]$ ]] || abort "--level must be an integer 1..9"

# Normalize sources (expand to absolute paths)
abs() { readlink -f -- "$1"; }
declare -a ABS_SOURCES=()
for s in "${SOURCES[@]}"; do
  [[ -e "$s" ]] || abort "Source not found: $s"
  ABS_SOURCES+=("$(abs "$s")")
done

DEST_DIR="$(mkdir -p -- "$DEST_DIR" && abs "$DEST_DIR")"

# ---------- Size & FS planning ----------
bytes_sum() {
  local total=0 v
  for p in "$@"; do
    v=$(du -sb --apparent-size -- "$p" | awk '{print $1}')
    total=$((total + v))
  done
  printf '%s\n' "$total"
}
fmt_bytes() {
  local b=$1
  awk -v b="$b" 'function human(x){ s="B K M G T P E"; split(s,a," "); i=1; while (x>=1024 && i<7){x/=1024;i++} printf "%.2f %s", x, a[i]; }
                 BEGIN{ human(b) }'
}
fs_mount() { df -P -- "$1" | awk 'NR==2{print $6}'; }
fs_free()  { df -PB1 -- "$1" | awk 'NR==2{print $4}'; }

TOTAL_SRC_BYTES=$(bytes_sum "${ABS_SOURCES[@]}")
SRC_FS_MOUNT=$(fs_mount "$(dirname "${ABS_SOURCES[0]}")")
SRC_FS_FREE=$(fs_free "$SRC_FS_MOUNT")
DEST_FS_FREE=$(fs_free "$DEST_DIR")

# Conservative estimates:
#  - Inner .7z total ≈ TOTAL_SRC_BYTES * 1.02 (media often incompressible; add overhead)
#  - Outer tar.gz ≈ inner size * 1.00 (gzip of .7z yields negligible gain; treat as same ballpark)
INNER_EST=$(( (TOTAL_SRC_BYTES * 102) / 100 ))
OUTER_EST=$INNER_EST

if $DRY_RUN; then
  echo "=== DRY RUN (no changes) ==="
  echo "Sources:"
  for p in "${ABS_SOURCES[@]}"; do
    echo "  - $p"
  done
  echo "Destination: $DEST_DIR"
  echo "Total source size: $(fmt_bytes "$TOTAL_SRC_BYTES")"
  echo "Source FS free:    $(fmt_bytes "$SRC_FS_FREE")   (mount: $SRC_FS_MOUNT)"
  echo "Dest   FS free:    $(fmt_bytes "$DEST_FS_FREE")"
  echo "Estimated inner .7z total: $(fmt_bytes "$INNER_EST")"
  if [[ "$OUTER_FORMAT" == "tar.gz" ]]; then
    echo "Estimated outer tar.gz:     $(fmt_bytes "$OUTER_EST")"
    echo "Peak space considerations:"
    echo "  • On SOURCE FS: sources shrink as each is archived; inner .7z accumulate."
    echo "  • On DEST   FS: outer tar.gz is written directly here."
    echo "  • If DEST is same FS as sources, ensure roughly: sources + inner + outer."
  fi
  exit 0
fi

# Warn if clearly insufficient free space on DEST for outer
if [[ "$OUTER_FORMAT" == "tar.gz" ]]; then
  if (( DEST_FS_FREE < OUTER_EST )); then
    echo "Warning: Destination free space ($(fmt_bytes "$DEST_FS_FREE")) may be insufficient for outer archive ($(fmt_bytes "$OUTER_EST"))." >&2
  fi
fi

# ---------- Work ----------
cd "$DEST_DIR"

declare -a INNER_ARCHIVES=()
confirm_delete() {
  $CONFIRM || return 0
  local target=$1
  read -r -p "Delete original source '$target'? [y/N] " ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]]
}

archive_one() {
  local src="$1"
  local base
  base="$(basename "$src")"
  local out="${base}.7z"

  if [[ -e "$out" && $FORCE == false ]]; then
    abort "Output exists: $out (use --force to overwrite)"
  fi
  [[ -e "$out" ]] && rm -f -- "$out"

  echo ">>> Archiving '$src' -> '$DEST_DIR/$out'"
  # -p without value forces secure interactive prompt; -mhe=on encrypts names; -mx sets compression level
  7z a -t7z -p -mhe=on -mx="$LEVEL" -- "$out" "$src"

  echo ">>> Created: $out"
  INNER_ARCHIVES+=("$out")

  if $PRESERVE_SOURCE; then
    echo "Preserving source: $src"
  else
    if confirm_delete "$src"; then
      echo "Deleting source: $src"
      rm -rf -- "$src"
    else
      echo "Skipped deletion of: $src"
    fi
  fi
}

# Archive each source immediately and optionally delete it
for src in "${ABS_SOURCES[@]}"; do
  archive_one "$src"
done

# Outer bundle if requested
if [[ "$OUTER_FORMAT" == "tar.gz" ]]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  BUNDLE="bundle-${TS}.tar.gz"
  echo ">>> Creating outer tar.gz: $DEST_DIR/$BUNDLE"
  # Stream tar -> gzip directly into destination
  tar -cvf - -- "${INNER_ARCHIVES[@]}" | gzip -9 > "$BUNDLE"

  echo ">>> Wrapping outer tar.gz in 7z with separate password"
  BUNDLE_7Z="${BUNDLE}.7z"
  if [[ -e "$BUNDLE_7Z" && $FORCE == false ]]; then
    abort "Output exists: $BUNDLE_7Z (use --force to overwrite)"
  fi
  [[ -e "$BUNDLE_7Z" ]] && rm -f -- "$BUNDLE_7Z"

  # Secure interactive prompt for outer password
  7z a -t7z -p -mhe=on -mx="$LEVEL" -- "$BUNDLE_7Z" "$BUNDLE"
  rm -f -- "$BUNDLE"
  echo ">>> Created: $BUNDLE_7Z"

  if $REMOVE_INTERMEDIATE; then
    echo "Removing inner .7z intermediates:"
    printf '  %s\n' "${INNER_ARCHIVES[@]}"
    rm -f -- "${INNER_ARCHIVES[@]}"
  fi
fi

echo "All done."
