#!/usr/bin/env bash

#===============================================================================
# ssh-time
#
# Wrapper around ssh-agent + ssh-add that:
#   • Sets a key lifetime using hours/minutes/seconds
#   • Prints a human-readable duration
#   • Prints the same duration in total seconds
#   • Shows current time and when the key will expire (with timezone info)
#
# Usage:
#   ssh-time [-s | --seconds N] [-m | --minutes N] [-h | --hours N] [--key PATH]
#
# Defaults:
#   --key defaults to: \$HOME/.ssh/id_rsa
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

#------------------------------------------------------------------------------
# Usage
#------------------------------------------------------------------------------
function usage() {
  echo "Usage: $0 [-s | --seconds N] [-m | --minutes N] [-h | --hours N] [--key PATH]"
  echo "Provide at least one of -s/-m/-h to specify time."
  echo "The key path is optional and defaults to \$HOME/.ssh/id_rsa."
  exit 1
}

#------------------------------------------------------------------------------
# Parse arguments
#------------------------------------------------------------------------------
seconds=0
minutes=0
hours=0
key_path="$HOME/.ssh/id_rsa"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
  -s | --seconds)
    [[ $# -lt 2 ]] && usage
    seconds="$2"
    shift 2
    ;;
  -m | --minutes)
    [[ $# -lt 2 ]] && usage
    minutes="$2"
    shift 2
    ;;
  -h | --hours)
    [[ $# -lt 2 ]] && usage
    hours="$2"
    shift 2
    ;;
  --key)
    [[ $# -lt 2 ]] && usage
    key_path="$2"
    shift 2
    ;;
  *)
    usage
    ;;
  esac
done

# Validate inputs
if [[ "$seconds" -eq 0 && "$minutes" -eq 0 && "$hours" -eq 0 ]]; then
  usage
fi

# Ensure non-negative integers (simple sanity check)
if ! [[ "$seconds" =~ ^[0-9]+$ && "$minutes" =~ ^[0-9]+$ && "$hours" =~ ^[0-9]+$ ]]; then
  echo "All time values must be non-negative integers." >&2
  exit 1
fi

#------------------------------------------------------------------------------
# Calculate total time in seconds
#------------------------------------------------------------------------------
total_seconds=$((seconds + minutes * 60 + hours * 3600))
if ((total_seconds <= 0)); then
  echo "Total time must be greater than zero." >&2
  exit 1
fi

#------------------------------------------------------------------------------
# Format and print time
#------------------------------------------------------------------------------
function format_time() {
  local total="$1"
  local h m s

  h=$((total / 3600))
  m=$(((total % 3600) / 60))
  s=$((total % 60))

  if ((total < 60)); then
    # < 1 minute
    # Time: X seconds (Y.yy minutes, N seconds in total)
    printf "Time: %d seconds (%.2f minutes, %d seconds in total)\n" \
      "$total" "$(bc -l <<<"$total / 60")" "$total"
  elif ((total < 3600)); then
    # < 1 hour
    # Time: M minutes, S seconds (H.hh hours, N seconds in total)
    printf "Time: %d minutes, %d seconds (%.2f hours, %d seconds in total)\n" \
      "$m" "$s" "$(bc -l <<<"$total / 3600")" "$total"
  else
    # >= 1 hour
    # Time: H hours, M minutes, S seconds (N seconds in total)
    printf "Time: %d hours, %d minutes, %d seconds (%d seconds in total)\n" \
      "$h" "$m" "$s" "$total"
  fi
}

#------------------------------------------------------------------------------
# Start ssh-agent and add key with timeout
#------------------------------------------------------------------------------
eval "$(ssh-agent -s)"
ssh-add -t "$total_seconds" "$key_path"

#------------------------------------------------------------------------------
# Report duration in a richer form
#------------------------------------------------------------------------------
format_time "$total_seconds"

#------------------------------------------------------------------------------
# Show current time and expiry time (with timezone)
#------------------------------------------------------------------------------
current_epoch="$(date +%s)"
expiry_epoch=$((current_epoch + total_seconds))

current_str="$(date '+%Y-%m-%d %H:%M:%S %Z (UTC%z)')"
expiry_str="$(date -d "@$expiry_epoch" '+%Y-%m-%d %H:%M:%S %Z (UTC%z)')"

echo "Current time : $current_str"
echo "Expires at   : $expiry_str"
