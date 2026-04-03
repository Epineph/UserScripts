#!/usr/bin/env bash
#===============================================================================
# 7z-wrap
#
# Wrapper around 7z with:
#   • Mode presets: fastest / fast / balanced / slow
#   • Optional max-compression alias
#   • Custom compression level and threads
#   • Optional password protection with header hiding
#   • Optional deletion of source files after success
#
# Usage:
#   7z-wrap [options] ARCHIVE.7z SOURCE [SOURCE ...]
#
# Notes:
#   • Uses 7z format (-t7z) explicitly.
#   • Password protection uses -p (prompt from 7z), not -pPASSWORD.
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
function show_help() {
  local default_pager pager
  if command -v less >/dev/null 2>&1; then
    default_pager="less -R"
  else
    default_pager="cat"
  fi
  pager="${HELP_PAGER:-$default_pager}"

  if [[ "$pager" == "cat" ]]; then
    cat <<EOF
Usage: $(basename "$0") [options] ARCHIVE.7z SOURCE [SOURCE ...]

Mode presets (mutually exclusive with --compression-level / --threads):
  -m, --mode <fastest|fast|balanced|slow>
      fastest  → -mx0  -mmt=on  (store only, maximum speed)
      fast     → -mx1  -mmt=on  (very fast, light compression)
      balanced → -mx5  -mmt=on  (middle ground)
      slow     → -mx9  -mmt=on  (maximum compression; slowest)

  --max-compression
      Alias for --mode slow (mx9, all threads).

Custom compression (no mode / max-compression used):
  --compression-level N
      Map directly to -mxN (N in 0–9). Default: 1 if not specified.
  --threads N
      Map directly to -mmtN, where 1 <= N <= number of logical CPUs.
      Default: all threads (-mmt=on) if not specified.

Encryption:
  -p, --password-protect
      Use 7z format with header encryption:
        -t7z -mhe=on -p
      7z will prompt interactively for the password.
      Password is NOT placed on the command line.

Source deletion:
  --delete-source
      After successful archive creation, prompt to delete SOURCE(s).
      No deletion occurs on failure or if you answer "no".

General:
  -h, --help
      Show this help text.

Examples:
  Fastest (store only, no compression):
    $(basename "$0") -m fastest backup.7z ~/data

  Balanced, password-protected, then delete sources:
    $(basename "$0") --mode balanced -p --delete-source backup.7z ~/data

  Custom: mx3 with 4 threads:
    $(basename "$0") --compression-level 3 --threads 4 backup.7z ~/data
EOF
  else
    cat <<EOF | $pager
Usage: $(basename "$0") [options] ARCHIVE.7z SOURCE [SOURCE ...]

Mode presets (mutually exclusive with --compression-level / --threads):
  -m, --mode <fastest|fast|balanced|slow>
      fastest  → -mx0  -mmt=on  (store only, maximum speed)
      fast     → -mx1  -mmt=on  (very fast, light compression)
      balanced → -mx5  -mmt=on  (middle ground)
      slow     → -mx9  -mmt=on  (maximum compression; slowest)

  --max-compression
      Alias for --mode slow (mx9, all threads).

Custom compression (no mode / max-compression used):
  --compression-level N
      Map directly to -mxN (N in 0–9). Default: 1 if not specified.
  --threads N
      Map directly to -mmtN, where 1 <= N <= number of logical CPUs.
      Default: all threads (-mmt=on) if not specified.

Encryption:
  -p, --password-protect
      Use 7z format with header encryption:
        -t7z -mhe=on -p
      7z will prompt interactively for the password.
      Password is NOT placed on the command line.

Source deletion:
  --delete-source
      After successful archive creation, prompt to delete SOURCE(s).
      No deletion occurs on failure or if you answer "no".

General:
  -h, --help
      Show this help text.

Examples:
  Fastest (store only, no compression):
    $(basename "$0") -m fastest backup.7z ~/data

  Balanced, password-protected, then delete sources:
    $(basename "$0") --mode balanced -p --delete-source backup.7z ~/data

  Custom: mx3 with 4 threads:
    $(basename "$0") --compression-level 3 --threads 4 backup.7z ~/data
EOF
  fi
}

#-------------------------------------------------------------------------------
# Ensure 7z exists
#-------------------------------------------------------------------------------
if ! command -v 7z >/dev/null 2>&1; then
  echo "Error: '7z' not found in PATH." >&2
  exit 1
fi

#-------------------------------------------------------------------------------
# Defaults / state
#-------------------------------------------------------------------------------
MODE=""
MAX_COMPRESSION=0
COMP_LEVEL=""
THREADS=""
PASSWORD_PROTECT=0
DELETE_SOURCE=0

#-------------------------------------------------------------------------------
# Parse options
#-------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--mode)
      [[ $# -lt 2 ]] && { echo "Error: --mode requires an argument." >&2; exit 1; }
      MODE="$2"
      # Case-insensitive mode names
      MODE="${MODE,,}"
      shift 2
      ;;
    --max-compression)
      MAX_COMPRESSION=1
      shift
      ;;
    --compression-level)
      [[ $# -lt 2 ]] && { echo "Error: --compression-level requires N." >&2; exit 1; }
      COMP_LEVEL="$2"
      shift 2
      ;;
    --threads)
      [[ $# -lt 2 ]] && { echo "Error: --threads requires N." >&2; exit 1; }
      THREADS="$2"
      shift 2
      ;;
    -p|--password-protect)
      PASSWORD_PROTECT=1
      shift
      ;;
    --delete-source)
      DELETE_SOURCE=1
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

#-------------------------------------------------------------------------------
# Remaining args: ARCHIVE and SOURCES
#-------------------------------------------------------------------------------
if [[ $# -lt 2 ]]; then
  echo "Error: need ARCHIVE and at least one SOURCE." >&2
  echo "Try: $(basename "$0") --help" >&2
  exit 1
fi

archive="$1"
shift
sources=( "$@" )

#-------------------------------------------------------------------------------
# Mutual exclusivity checks
#-------------------------------------------------------------------------------
if [[ -n "$MODE" || $MAX_COMPRESSION -eq 1 ]]; then
  if [[ -n "${COMP_LEVEL:-}" || -n "${THREADS:-}" ]]; then
    echo "Error: --mode/--max-compression cannot be combined with" >&2
    echo "       --compression-level or --threads." >&2
    exit 1
  fi
fi

# Validate mode if set
if [[ -n "$MODE" ]]; then
  case "$MODE" in
    fastest|fast|balanced|slow) ;;
    *)
      echo "Error: invalid mode '$MODE' (expected fastest|fast|balanced|slow)." >&2
      exit 1
      ;;
  esac
fi

#-------------------------------------------------------------------------------
# Determine compression args
#-------------------------------------------------------------------------------
compression_args=()

if [[ -n "$MODE" || $MAX_COMPRESSION -eq 1 ]]; then
  # Mode or max-compression
  local_mode="$MODE"
  if (( MAX_COMPRESSION == 1 )); then
    local_mode="slow"
  fi

  case "$local_mode" in
    fastest)
      compression_args+=( "-mx0" "-mmt=on" )
      ;;
    fast)
      compression_args+=( "-mx1" "-mmt=on" )
      ;;
    balanced)
      compression_args+=( "-mx5" "-mmt=on" )
      ;;
    slow)
      compression_args+=( "-mx9" "-mmt=on" )
      ;;
  esac
else
  # Custom compression-level / threads
  if [[ -z "$COMP_LEVEL" ]]; then
    COMP_LEVEL="1"
  fi

  if ! [[ "$COMP_LEVEL" =~ ^[0-9]$ ]]; then
    echo "Error: --compression-level must be a single digit 0–9." >&2
    exit 1
  fi

  compression_args+=( "-mx$COMP_LEVEL" )

  if [[ -z "${THREADS:-}" ]]; then
    compression_args+=( "-mmt=on" )
  else
    if ! [[ "$THREADS" =~ ^[0-9]+$ ]]; then
      echo "Error: --threads must be a positive integer." >&2
      exit 1
    fi

    # Determine max logical CPUs
    max_cpus="1"
    if command -v nproc >/dev/null 2>&1; then
      max_cpus="$(nproc 2>/dev/null || echo 1)"
    else
      max_cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
    fi

    if (( THREADS < 1 || THREADS > max_cpus )); then
      echo "Error: --threads=$THREADS exceeds available CPUs ($max_cpus)." >&2
      exit 1
    fi

    compression_args+=( "-mmt=$THREADS" )
  fi
fi

#-------------------------------------------------------------------------------
# Encryption args
#-------------------------------------------------------------------------------
enc_args=( "-t7z" )  # always use 7z format explicitly

if (( PASSWORD_PROTECT == 1 )); then
  enc_args+=( "-mhe=on" "-p" )
fi

#-------------------------------------------------------------------------------
# Confirm deletion, if requested
#-------------------------------------------------------------------------------
if (( DELETE_SOURCE == 1 )); then
  echo "You requested --delete-source. The following will be deleted AFTER"
  echo "a successful archive creation:"
  printf '  %s\n' "${sources[@]}"
  printf 'Archive: %s\n' "$archive"
  read -r -p "Proceed with source deletion? [y/N] " answer
  case "$answer" in
    [yY]|[yY][eE][sS]) ;;
    *)
      echo "Skipping source deletion."
      DELETE_SOURCE=0
      ;;
  esac
fi

#-------------------------------------------------------------------------------
# Run 7z
#-------------------------------------------------------------------------------
echo "→ Creating archive: $archive"
echo "→ Compression args: ${compression_args[*]}"
if (( PASSWORD_PROTECT == 1 )); then
  echo "→ Password protection: enabled (header encryption on; 7z will prompt)."
fi

set -x
7z a "${compression_args[@]}" "${enc_args[@]}" -- "$archive" "${sources[@]}"
set +x

echo "✔ Archive created."

#-------------------------------------------------------------------------------
# Delete sources if requested and archive succeeded
#-------------------------------------------------------------------------------
if (( DELETE_SOURCE == 1 )); then
  echo "→ Deleting source files/directories..."
  rm -rf -- "${sources[@]}"
  echo "✔ Sources deleted."
fi

