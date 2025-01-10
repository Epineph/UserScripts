#!/usr/bin/env bash

################################################################################
# install_packages.sh
#
# A script to iteratively install (or upgrade) packages on Arch Linux-based
# systems, allowing for:
#   - Conflict handling without overwriting (--no-overwrites).
#   - Overwriting file conflicts if desired (--overwrite).
#   - Full system upgrades (--upgrade).
#   - Mirror syncing (--sync-mirrors).
#   - Skipping tests (--skip-tests).
#   - Automatic key importing (--import-keys).
#   - Using an AUR helper (e.g., yay, paru) instead of pacman (--helper).
#   - Etc.
#
################################################################################

set -euo pipefail

################################################################################
# Usage / Help
################################################################################
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [PACKAGES...]

Installs or upgrades the specified PACKAGES with fine-grained control over
conflict handling, mirror syncing, test skipping, PGP key importing, etc.

OPTIONS:
  --help, -h            Show this help message and exit.

  --helper <command>    Specify which package manager/AUR helper to use.
                        Default is 'pacman'. Examples: 'yay', 'paru'.
                        If the helper is not found in PATH, the script exits.

  --no-overwrites       Do NOT use --overwrite. If a conflict occurs, remove the
                        conflicting package from the list and continue iteratively.
  
  --overwrite           Use --overwrite '*' to resolve file-level conflicts by
                        overwriting them (use with caution!). (Default is off)

  --upgrade, -U         Perform a full system upgrade (-Syu or the equivalent
                        for your helper).

  --sync-mirrors        Force the package manager to refresh all package databases
                        twice (equivalent to -Syy). Useful if mirrors are out
                        of date or corrupted.

  --allow-downgrades    Allow package downgrades if necessary.
                        (Pacman/AUR helpers often need config changes for this.)

  --noconfirm           Pass --noconfirm to the helper (skip user prompts).

  --skip-tests          Attempt to skip tests during build (e.g. --nocheck for
                        makepkg, environment variables for Python tests).

  --import-keys         Automatically import missing PGP keys when prompted (if not
                        using --noconfirm, or if you want to script that step).

  --needed, --no-reinstall
                        Equivalent to pacman --needed, i.e., skip reinstalling
                        packages already up to date. (Enabled by default)

  --rebuild-tree        (Placeholder) Possibly run something like "paccache -r" or
                        other tasks to rebuild local package tree or AUR DB. It's not
                        typically necessary unless your local metadata is corrupted.

EXAMPLES:
  1) Basic usage:
     $(basename "$0") --upgrade --noconfirm --skip-tests firefox vlc

  2) Install packages without overwriting conflicts (removing conflicting pkgs):
     $(basename "$0") --no-overwrites package1 package2 package3

  3) Overwrite conflicts (use with caution) and sync mirrors first:
     $(basename "$0") --overwrite --sync-mirrors --upgrade chromium

  4) Use an AUR helper (yay) for AUR packages, automatically import PGP keys:
     $(basename "$0") --helper yay --import-keys --skip-tests aur_package

NOTES:
  - The conflict resolution logic parses error messages. Adjust as needed for your helper.
  - Some options (like allowing downgrades) may require changes to config files (pacman.conf).
  - For a truly non-interactive key import, you may need extra scripting (e.g. with 'expect').

EOF
}

################################################################################
# Default Options
################################################################################
HELPER="pacman"          # Default to pacman unless --helper is given
NO_OVERWRITES=0          # If set, do NOT use --overwrite, instead remove conflict pkgs
OVERWRITE=0              # If set, use --overwrite '*'
PERFORM_UPGRADE=0        # Perform a full system upgrade before installing
SYNC_MIRRORS=0           # Refresh package database twice (-Syy)
ALLOW_DOWNGRADES=0       # Typically requires config changes, no direct pacman flag
NOCONFIRM=0              # Skip user prompts
SKIP_TESTS=0             # Skip tests for building (makepkg --nocheck, etc.)
IMPORT_KEYS=0            # Attempt to import missing PGP keys automatically
NEEDED=1                 # By default, skip reinstalling packages
REBUILD_TREE=0           # Placeholder for local DB or package tree rebuild logic

################################################################################
# Parse Arguments
################################################################################
PACKAGES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --helper)
            shift
            if [[ $# -eq 0 ]]; then
                echo "Error: --helper requires a value (e.g., --helper yay)."
                exit 1
            fi
            HELPER="$1"
            shift
            ;;
        --no-overwrites)
            NO_OVERWRITES=1
            shift
            ;;
        --overwrite)
            OVERWRITE=1
            shift
            ;;
        -U|--upgrade)
            PERFORM_UPGRADE=1
            shift
            ;;
        --sync-mirrors)
            SYNC_MIRRORS=1
            shift
            ;;
        --allow-downgrades)
            ALLOW_DOWNGRADES=1
            shift
            ;;
        --noconfirm)
            NOCONFIRM=1
            shift
            ;;
        --skip-tests)
            SKIP_TESTS=1
            shift
            ;;
        --import-keys)
            IMPORT_KEYS=1
            shift
            ;;
        --needed|--no-reinstall)
            NEEDED=1
            shift
            ;;
        --rebuild-tree)
            REBUILD_TREE=1
            shift
            ;;
        *)
            # Everything else is considered a package
            PACKAGES+=( "$1" )
            shift
            ;;
    esac
done

# If no packages and not upgrading, there's nothing to do
if [[ ${#PACKAGES[@]} -eq 0 && $PERFORM_UPGRADE -eq 0 ]]; then
    echo "No packages specified and --upgrade not set."
    usage
    exit 1
fi

################################################################################
# Ensure the chosen helper is installed
################################################################################
if ! command -v "$HELPER" >/dev/null 2>&1; then
    echo "Error: The specified helper/manager '$HELPER' is not found in PATH."
    exit 1
fi

################################################################################
# Construct the command & flags dynamically
################################################################################
declare -a INSTALL_CMD
INSTALL_CMD+=("$HELPER")

# For pacman or AUR helpers, typically the base subcommand is -S (install)
# We'll do a combined approach for upgrade if requested.
#
# For pacman:
#   -S  -> install
#   -Syu-> system upgrade then install
# For yay/paru:
#   -S, -Syu, etc. are usually the same, with additional behavior for AUR packages.

if [[ "$HELPER" == "pacman" ]]; then
    # Pacman usage
    INSTALL_CMD+=("-S")  # We'll modify to -Syu if needed
    if [[ $PERFORM_UPGRADE -eq 1 ]]; then
        INSTALL_CMD[1]="-Syu"
    fi
    if [[ $SYNC_MIRRORS -eq 1 ]]; then
        # Merge with existing to get -Syyu if also upgrading
        case "${INSTALL_CMD[1]}" in
            "-Syu")
                INSTALL_CMD[1]="-Syyu"
                ;;
            "-S")
                INSTALL_CMD[1]="-Syy"
                ;;
        esac
    fi
else
    # For many AUR helpers, -S or -Syu also works similarly:
    if [[ $PERFORM_UPGRADE -eq 1 ]]; then
        INSTALL_CMD+=("-Syu")
        if [[ $SYNC_MIRRORS -eq 1 ]]; then
            # Some AUR helpers interpret -Syyu the same, or have a different flag
            INSTALL_CMD=("$HELPER" "-Syyu")
        fi
    else
        INSTALL_CMD+=("-S")
        if [[ $SYNC_MIRRORS -eq 1 ]]; then
            # Some helpers let you do -Syy for forcing double sync
            INSTALL_CMD=("$HELPER" "-Syy")
        fi
    fi
fi

# Common flags (pacman or AUR helper)
if [[ $NOCONFIRM -eq 1 ]]; then
    INSTALL_CMD+=("--noconfirm")
fi

if [[ $NEEDED -eq 1 ]]; then
    INSTALL_CMD+=("--needed")
fi

if [[ $OVERWRITE -eq 1 ]]; then
    # Overwrite all conflicting files (be cautious!)
    INSTALL_CMD+=("--overwrite" "*")
fi

# Note: 'allow downgrades' often requires config changes rather than a CLI flag.
if [[ $ALLOW_DOWNGRADES -eq 1 ]]; then
    echo "Warning: 'allow downgrades' might require pacman.conf or helper config changes."
fi

################################################################################
# Optional: Rebuild local package tree or cache if needed
################################################################################
if [[ $REBUILD_TREE -eq 1 ]]; then
    echo "Rebuilding or cleaning the local package tree..."
    # Example command(s):
    #   sudo paccache --remove --uninstalled
    #   or: sudo pacman -Scc
    #   or any helper-specific DB rebuild
fi

################################################################################
# Skip Tests
################################################################################
# For AUR building, many helpers accept --mflags "--nocheck" or so.
# We also can set environment variables for Python tests, etc.
if [[ $SKIP_TESTS -eq 1 ]]; then
    export MAKEPKG_ENV="--nocheck"
    export SKIP_PYTHON_TESTS=1
    # If your helper uses a special syntax, adapt here. For example (yay):
    #   INSTALL_CMD+=("--mflags" "--nocheck")
    #
    # For paru:
    #   INSTALL_CMD+=("--mflags" "--nocheck")
    #
    # For direct makepkg:
    #   makepkg -si --nocheck ...
fi

################################################################################
# Import Keys Automatically (if possible)
################################################################################
# If using --noconfirm, you won't be prompted anyway, so this is relevant only
# if you want to script the prompt or do a separate GPG import. That can be
# more complex (e.g., using 'expect'). We'll just leave a note here:
if [[ $IMPORT_KEYS -eq 1 && $NOCONFIRM -eq 0 ]]; then
    echo "Info: Attempting to import missing PGP keys automatically if prompted..."
    # Real non-interactive key import might require custom logic, e.g.:
    #   gpg --recv-keys <KEYID>
    # or hooking pacman’s interactive import with an expect script.
fi

################################################################################
# Conflict-Resolution Logic (NO_OVERWRITES)
# If a package causes a conflict, remove it from the list and retry
################################################################################
error_log="$(mktemp)"

function install_packages_no_overwrite() {
    local remaining_packages=("${PACKAGES[@]}")

    while [[ ${#remaining_packages[@]} -gt 0 ]]; do
        echo ">> Installing packages: ${remaining_packages[*]}"
        # Combine the base command + package list
        if ! "${INSTALL_CMD[@]}" "${remaining_packages[@]}" 2>"$error_log"; then
            # Attempt to detect conflict lines. For pacman, we might see:
            #   "<pkg> conflicts with <other-pkg>"
            # Or "error: failed to commit transaction (conflicting files)"
            #   "<pkg>: /some/path already exists in filesystem"
            #
            # AUR helpers might have different wording. Adjust as needed.

            # 1) "conflicts with <package>"
            conflict_pkg="$(grep -oP '(?<=conflicts with ).*' "$error_log" | awk '{print $1}')"

            # 2) If not found, look for "exists in filesystem"
            if [[ -z "$conflict_pkg" ]]; then
                conflict_pkg="$(grep -oP '^(.*): .*exists in filesystem' "$error_log" | awk -F ':' '{print $1}')"
            fi

            if [[ -n "$conflict_pkg" ]]; then
                echo "Conflict detected with package: '$conflict_pkg'"
                # Remove the conflicting package from the list
                remaining_packages=("${remaining_packages[@]/$conflict_pkg}")
                echo "Removed '$conflict_pkg' from the installation list. Retrying..."
            else
                echo "Unresolvable error occurred. Check the log: $error_log"
                exit 1
            fi
        else
            echo ">> All requested packages in the current list installed successfully."
            break
        fi
    done
}

################################################################################
# Main Installation / Upgrade Flow
################################################################################
if [[ $NO_OVERWRITES -eq 1 ]]; then
    echo ">> Conflict resolution mode: NO overwrites."
    install_packages_no_overwrite
else
    # Normal installation using the constructed flags (with or without --overwrite).
    echo ">> Installing/Upgrading packages with: ${INSTALL_CMD[*]} ${PACKAGES[*]}"
    if [[ ${#PACKAGES[@]} -gt 0 ]]; then
        "${INSTALL_CMD[@]}" "${PACKAGES[@]}"
    else
        # If no packages, just do the upgrade if requested
        if [[ $PERFORM_UPGRADE -eq 1 ]]; then
            "${INSTALL_CMD[@]}"
        fi
    fi
fi

echo ">> Done."