#!/usr/bin/env bash
# ==============================================================================
# Script: save_script.sh
# Author:  <your-name>
# Version: 1.2 – 2025-05-29
# --------------------------------------------------------------------------
# PURPOSE
#   Copy one or more scripts to /usr/local/bin **without the original
#   extension** (e.g. my_util.sh → /usr/local/bin/my_util).
#
#   Compared with the earlier version this release:
#     1.  Detects whether a destination file is **identical** (byte-for-byte)
#         to the incoming source.  Identical duplicates are silently skipped.
#     2.  If the destination exists **and differs**, all such conflicts are
#         collected first.  The user is told how many there are and can choose
#         to:
#           •  [A]  overwrite all differing duplicates;
#           •  [R]  review each diff interactively and decide per file;
#           •  [K]  keep all existing versions (skip all conflicting copies).
#     3.  When reviewing, the script displays a coloured, side-by-side diff
#         using the first tool found in this priority order:
#              git-delta ▸ diff-so-fancy ▸ bat --diff ▸ plain diff -u
#
#   The script reinvokes itself via sudo when run by a non-root user.
#
# USAGE
#   ./save_script.sh  file1.sh  file2.py  file3.R …
#
# EXIT CODES
#   0  success
#   1  incorrect invocation (no arguments)
#   2  copy error (details printed inline)
# ==============================================================================
#set -euo pipefail
IFS=$'\n\t'

###############################################################################
# CONFIGURATION
###############################################################################
DEST_DIR="/usr/local/bin"                  # Change if needed.
DIFF_TOOL=""                               # Autodetected later.

###############################################################################
# HELPER FUNCTIONS
###############################################################################

#--- Determine the prettiest diff tool available ------------------------------
detect_diff_tool() {
    if command -v delta &>/dev/null;          then DIFF_TOOL="delta"
    elif command -v diff-so-fancy &>/dev/null;then DIFF_TOOL="diff-so-fancy"
    elif command -v bat &>/dev/null;          then DIFF_TOOL="bat --diff"
    else                                           DIFF_TOOL="diff -u"
    fi
}

#--- Show a coloured diff between two files -----------------------------------
show_diff() {
    local old="$1" new="$2"
    case "$DIFF_TOOL" in
        delta)            delta    "$old" "$new" ;;
        diff-so-fancy)    git diff --no-index --color "$old" "$new" | diff-so-fancy ;;
        "bat --diff")     bat --diff "$old" "$new" ;;
        *)                diff -u "$old" "$new" ;;
    esac
}

#--- Ensure we are running with root privileges -------------------------------
ensure_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        exec sudo --preserve-env=PATH "$0" "$@"
    fi
}

#--- Copy one file, overwriting destination -----------------------------------
copy_file() {
    local src="$1" dest="$2"
    cp --preserve=mode,timestamps "$src" "$dest"
    echo "✔ Copied  $(basename "$src") → ${dest}"
}

###############################################################################
# MAIN LOGIC
###############################################################################
main() {
    #---------------------------------- preliminaries --------------------------
    ensure_root "$@"
    detect_diff_tool

    [[ $# -ge 1 ]] || { echo "Usage: $0 file1 [file2 …]" >&2; exit 1; }

    #---------------------------------- pass 1: classify -----------------------
    declare -a to_copy                # files whose dest does not yet exist
    declare -a identical=()           # (“src|dest”) pairs, content identical
    declare -a differing=()           # (“src|dest”) pairs, content differs

    for src in "$@"; do
        if [[ ! -f "$src" ]]; then
            echo "⚠ File '$src' does not exist – skipped."
            continue
        fi

        base="$(basename "${src%.*}")"
        dest="${DEST_DIR}/${base}"

        if [[ ! -e "$dest" ]]; then
            to_copy+=("$src|$dest")
        elif cmp -s "$src" "$dest"; then
            identical+=("$src|$dest")
        else
            differing+=("$src|$dest")
        fi
    done

    #---------------------------------- summary --------------------------------
    [[ ${#identical[@]} -gt 0 ]] &&
        printf "ℹ  %d identical duplicate(s) skipped automatically.\n" "${#identical[@]}"

    #---------------------------------- resolve differing duplicates -----------
    if [[ ${#differing[@]} -gt 0 ]]; then
        printf "\n⚠  %d duplicate file(s) with different content detected.\n" "${#differing[@]}"
        printf "   Choose an action:\n"
        printf "     [A] Overwrite all   [R] Review each   [K] Keep all → "
        read -r action
        action=${action:-K}
        case "${action^^}" in
            A)  for pair in "${differing[@]}"; do
                    IFS="|" read -r src dest <<< "$pair"
                    copy_file "$src" "$dest"
                done
                ;;
            R)  for pair in "${differing[@]}"; do
                    IFS="|" read -r src dest <<< "$pair"
                    printf "\n----- %s ↔ %s -----\n" "$src" "$dest"
                    show_diff "$dest" "$src"
                    printf "Overwrite? [y/N] "
                    read -r ans
                    if [[ "$ans" =~ ^[Yy]$ ]]; then
                        copy_file "$src" "$dest"
                    else
                        echo "✘ Kept    $(basename "$dest")"
                    fi
                done
                ;;
            K)  echo "✓ All differing duplicates kept."
                ;;
            *)  echo "Invalid choice – nothing changed." ;;
        esac
    fi

    #---------------------------------- copy new files -------------------------
    for pair in "${to_copy[@]}"; do
        IFS="|" read -r src dest <<< "$pair"
        copy_file "$src" "$dest"
    done
}

main "$@"

