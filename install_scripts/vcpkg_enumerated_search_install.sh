#!/usr/bin/env bash
###############################################################################
# enumerated_vcpkg_install.sh
#
# A script to search for and install ports from vcpkg on Linux/Unix systems.
#
# Usage:
#   ./enumerated_vcpkg_install.sh [searchTerm]
#
# Examples:
#   1) ./enumerated_vcpkg_install.sh              # prompts for search term interactively
#   2) ./enumerated_vcpkg_install.sh boost        # uses "boost" as the search term
#
# Description:
#   - This script searches the vcpkg repository for the specified term.
#   - Displays the search results with numeric indices.
#   - Prompts the user to choose which ports to install (accepts indices,
#     including comma/space-separated values and ranges such as "1-3").
#   - Installs each chosen port using "vcpkg install".
#
# Note:
#   If vcpkg search attempts to use a pager or awaits interactive input,
#   piping its output through 'cat' ensures that all output is flushed.
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
  cat <<EOF
Usage: $0 [searchTerm]

If searchTerm is omitted, you will be prompted to enter one.

Examples:
  $0
  $0 boost

EOF
  exit 0
}

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
  # This prevents vcpkg from hanging if it tries to invoke a pager.
  local search_results
  search_results="$(vcpkg search "$term" | cat 2>/dev/null)"

  # Check if any results were returned
  if [[ -z "$search_results" ]]; then
    echo "No results found for '$term'."
    return
  fi

  # Convert results into an array, splitting on newlines.
  # Filter out lines that are disclaimers or blank.
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
      # Handle a range such as 1-3
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
    # Ignore invalid tokens
  done

  # Remove duplicates and sort the indices
  mapfile -t chosen_indices < <(printf "%s\n" "${chosen_indices[@]}" | sort -n -u)

  # Install each selected package
  for idx in "${chosen_indices[@]}"; do
    if (( idx < 0 || idx >= ${#lines[@]} )); then
      echo "Invalid index: $idx. Skipping."
      continue
    fi

    # Assume the port name is the first whitespace-delimited token on the line.
    port_name="$(echo "${lines[idx]}" | awk '{print $1}')"
    
    echo "Installing '$port_name'..."
    vcpkg install "$port_name"
  done
}

# -----------------------------------------------------------------------------
# Main Script Logic
# -----------------------------------------------------------------------------

# Check if help was requested
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  show_help
fi

# The first argument (if provided) is treated as the search term
search_and_install "$1"

