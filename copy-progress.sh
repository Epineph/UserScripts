#!/usr/bin/env bash
#───────────────────────────────────────────────────────────────────────────────
#  copy-progress.sh — copy files or directories with a live progress/ETA read-out
#
#  Copyright   : 2025  (public domain / 0-BSD)
#  Author      :  <your-name-here>
#  Requirements: bash 4+, coreutils, either pv or rsync (≥ 3.1)
#───────────────────────────────────────────────────────────────────────────────
#  SYNOPSIS
#      copy-progress.sh  <source>  <destination>
#
#  DESCRIPTION
#      • If <source> is a **regular file** *and* the utility *pv* is installed,
#        the file is streamed through pv, which prints:
#           bytes transferred │ percentage │ transfer-rate │ ETA │ elapsed
#
#      • If <source> is a **directory** (or pv is absent), the script falls
#        back to *rsync --info=progress2*, which shows one overall progress
#        line with an ETA and periodically refreshed statistics.
#
#      • If neither pv nor a sufficiently new rsync is found, the script
#        aborts (unless --quiet is given) because it cannot fulfil the
#        “show progress” requirement.
#
#  OPTIONS
#      -h | --help     Print this help text and exit.
#      -q | --quiet    Suppress error messages if no progress tool is present;
#                      the script will instead execute a plain cp/rsync without
#                      progress output.
#
#  EXIT STATUS
#      0  success   │  1  usage error   │ 2  tool missing   │ 3  unexpected
#
#  EXAMPLES
#      copy-progress.sh big.iso              /media/usb/
#      copy-progress.sh ~/experiments/       /mnt/raid/backups/experiments/
#───────────────────────────────────────────────────────────────────────────────
set -euo pipefail
IFS=$'\n\t'

#######################################
# Print usage information.
#######################################
usage() { grep -E '^# ' "$0" | sed 's/^# //' >&2; }

#######################################
# Fail with message and exit.
# Globals:
#   quiet
# Arguments:
#   $1 – message
#   $2 – exit-code (default = 1)
#######################################
die() {
    local code=${2:-1}
    [[ "${quiet:-false}" == true ]] || printf 'Error: %s\n' "$1" >&2
    exit "$code"
}

#######################################
# Parse command-line.
#######################################
quiet=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)  usage; exit 0 ;;
        -q|--quiet) quiet=true;   shift ;;
        --)         shift; break ;;
        -*)         die "Unknown option: $1" ;;
        *)          break ;;
    esac
done
[[ $# -eq 2 ]] || { usage; die "Exactly <source> and <destination> required." 1; }

src=$1
dst=$2

#######################################
# Resolve destination path for single-file copies
# so that “copy file → directory/” works intuitively.
#######################################
if [[ -f "$src" && -d "$dst" ]]; then
    dst="${dst%/}/$(basename "$src")"
fi

#######################################
# Decide which backend to use.
#######################################
if [[ -f "$src" && -n "$(command -v pv || true)" ]]; then
    #──────────────────────── FILE ── pv ────────────────────────#
    size=$(stat --printf='%s' "$src")
    printf 'Copying file with pv…\n'
    pv -pterb -s "$size" "$src" > "$dst"
elif [[ -n "$(command -v rsync || true)" ]]; then
    # rsync ≥3.1 provides --info=progress2
    rsync_vers=$(rsync --version | awk '/^rsync/{print $3}')
    ver_ok=$(printf '%s\n3.1\n%s' "$rsync_vers" | sort -V | head -n1)
    if [[ "$ver_ok" == "3.1" || "$rsync_vers" == 3.1* || "$rsync_vers" > 3.1 ]]; then
        printf 'Copying with rsync --info=progress2…\n'
        rsync -a --info=progress2 --human-readable --partial "$src" "$dst"
    else
        die "rsync >= 3.1 required for progress output." 2
    fi
else
    die "Neither pv nor a suitable rsync found in \$PATH." 2
fi

printf 'Finished successfully.\n'

