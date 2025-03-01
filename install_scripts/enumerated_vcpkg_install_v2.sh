#!/usr/bin/env bash
###############################################################################
# enumerated_vcpkg_install.sh
#
# A script to search for and install ports from vcpkg on Linux/Unix systems.
#
# Usage:
#   ./enumerated_vcpkg_install.sh [options] [searchTerm]
#
# Examples:
#   1) ./enumerated_vcpkg_install.sh
#         # Prompts for search term interactively.
#   2) ./enumerated_vcpkg_install.sh boost
#         # Uses "boost" as the search term.
#   3) ./enumerated_vcpkg_install.sh --recursive --keep-going --upgrade libpng
#         # Searches for "libpng" and installs it using the additional flags.
#
# Description:
#   - This script searches the vcpkg repository for the specified term.
#   - It displays the search results with numeric indices.
#   - It prompts the user to choose which ports to install (accepts indices,
#     including comma/space-separated values and ranges such as "1-3").
#   - It installs each chosen port using "vcpkg install", optionally with:
#         --keep-going   (continue on errors)
#         --recursive    (install dependencies recursively)
#         --upgrade      (upgrade the port if already installed)
#
# Note:
#   If vcpkg search attempts to use a pager or awaits interactive input,
#   piping its output through 'cat' (or 'bat' if available) ensures that all
#   output is flushed.
#
# Prerequisites:
#   - vcpkg must be installed and available in your PATH.
#   - Bash (or a compatible shell) is required.
#
# Author: Epineph
# Date:   2025-02-21
###############################################################################

# -----------------------------------------------------------------------------
# Function: show_help
# Description: Displays usage help for this script.
# -----------------------------------------------------------------------------
show_help() {
  if command -v bat >/dev/null 2>&1; then
    # Pipe the help text into bat for a prettier display.
    cat <<EOF | bat --style="grid,header,snip" --theme="TwoDark" --language=help --force-colorization --chop-long-lines --squeeze-blank --squeeze-limit=2 --paging=never --italic-text=always --tabs=2
Usage: $0 [options] [searchTerm]

Options:
  --keep-going   Continue installation if one port fails.
  --recursive    Install ports recursively (include dependencies).
  --upgrade      Upgrade the port if already installed.
  -h, --help     Display this help message.

Examples:
  $0
      (Prompts for search term interactively.)
  $0 boost
      (Searches for "boost".)
  $0 --recursive --keep-going --upgrade libpng
      (Searches for "libpng" and installs with additional flags.)
EOF
  else
    cat <<EOF
Usage: $0 [options] [searchTerm]

Options:
  --keep-going   Continue installation if one port fails.
  --recursive    Install ports recursively (include dependencies).
  --upgrade      Upgrade the port if already installed.
  -h, --help     Display this help message.

Examples:
  $0
      (Prompts for search term interactively.)
  $0 boost
      (Searches for "boost".)
  $0 --recursive --keep-going --upgrade libpng
      (Searches for "libpng" and installs with additional flags.)
EOF
  fi
  exit 0
}

# -----------------------------------------------------------------------------
# Global variables for additional flags.
# -----------------------------------------------------------------------------
KEEP_GOING=""
RECURSIVE=""
UPGRADE=""
SEARCH_TERM=""

# -----------------------------------------------------------------------------
# Argument Parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-going)
      KEEP_GOING="--keep-going"
      shift
      ;;
    --recursive)
      RECURSIVE="--recursive"
      shift
      ;;
    --upgrade)
      UPGRADE="--upgrade"
      shift
      ;;
    -h|--help)
      show_help
      ;;
    *)
      # Assume any non-option is the search term.
      if [[ -z "$SEARCH_TERM" ]]; then
        SEARCH_TERM="$1"
      else
        SEARCH_TERM="$SEARCH_TERM $1"
      fi
      shift
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Function: search_and_install
# Description: Performs the search using vcpkg and installs selected ports.
# -----------------------------------------------------------------------------
search_and_install() {
  local term="$1"

  # Prompt for the search term if not provided
  if [[ -z "$term" ]]; then
    read -rp "Enter the search term for vcpkg: " term
  fi

  echo "Searching for '$term'..."

  # Run the search command and pipe through cat to flush output.
  local search_results
  search_results="$(vcpkg search "$term" | cat 2>/dev/null)"

  # Check if any results were returned
  if [[ -z "$search_results" ]]; then
    echo "No results found for '$term'."
    return
  fi

  # Convert results into an array, splitting on newlines.
  mapfile -t lines < <(echo "$search_results" \
    | grep -vE "^(The result may be outdated|If your port is not listed|Run \`git pull\`)" \
    | sed '/^\s*$/d')

  if [[ ${#lines[@]} -eq 0 ]]; then
    echo "No valid entries found for '$term'."
    return
  fi

  # Enumerate and display results
  echo "Found the following entries:"
  local i=0
  for line in "${lines[@]}"; do
    echo "[$i] $line"
    ((i++))
  done

  # Prompt user for indices to install
  read -rp "Enter the indices to install (comma/space-separated, e.g. 1,2 3-5, or 'q' to quit): " selection

  if [[ "$selection" == "q" ]]; then
    echo "Exiting without installing."
    return
  fi

  # Parse the selection: support commas, spaces, and ranges (e.g., 1-3)
  IFS=' ,' read -ra tokens <<< "$selection"
  local -a chosen_indices=()
  for token in "${tokens[@]}"; do
    if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      if (( start <= end )); then
        for ((idx=start; idx<=end; idx++)); do
          chosen_indices+=( "$idx" )
        done
      else
        echo "Ignoring invalid range: $token"
      fi
    elif [[ "$token" =~ ^[0-9]+$ ]]; then
      chosen_indices+=( "$token" )
    fi
  done

  # Remove duplicates and sort the indices
  mapfile -t chosen_indices < <(printf "%s\n" "${chosen_indices[@]}" | sort -n -u)

  # Install each selected package with additional flags if specified
  for idx in "${chosen_indices[@]}"; do
    if (( idx < 0 || idx >= ${#lines[@]} )); then
      echo "Invalid index: $idx. Skipping."
      continue
    fi

    # Assume the port name is the first whitespace-delimited token on the line.
    port_name="$(echo "${lines[idx]}" | awk '{print $1}')"
    
    echo "Installing '$port_name'..."
    vcpkg install "$port_name" ${KEEP_GOING} ${RECURSIVE} ${UPGRADE}
  done
}

# -----------------------------------------------------------------------------
# Main Script Logic
# -----------------------------------------------------------------------------
search_and_install "$SEARCH_TERM"

