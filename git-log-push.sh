#!/usr/bin/env bash
#===============================================================================
# NAME
#   git-log-push.sh
#
# SYNOPSIS
#   git-log-push.sh [-m "custom message"] [-h]
#
# DESCRIPTION
#   Stages all changes, commits with a timestamp or custom message,
#   pushes to the current branch, and—on success—records:
#     • stdout+stderr of each step
#     • a side-by-side diff of HEAD~1 vs HEAD
#   into $HOME/.logs/YYYY-MM-DD/HH-MM-SS/log.txt.
#
# OPTIONS
#   -m   Provide a custom commit message. Defaults to ISO timestamp.
#   -h   Show this help and exit.
#===============================================================================

set -euo pipefail

print_help() {
  sed -n '1,60p' "$0"
}

# ————————————————————————————————————————————————————————————————
# Parse options
# ————————————————————————————————————————————————————————————————
commit_msg=""
while getopts ":m:h" opt; do
  case $opt in
    m) commit_msg="$OPTARG" ;;
    h) print_help; exit 0 ;;
    \?) echo "Invalid option: -$OPTARG" >&2; print_help; exit 1 ;;
    :)  echo "Option -$OPTARG requires an argument." >&2; exit 1 ;;
  esac
done

# If no custom message, use ISO 8601 timestamp
if [[ -z "$commit_msg" ]]; then
  commit_msg="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
fi

# ————————————————————————————————————————————————————————————————
# Build log path
# ————————————————————————————————————————————————————————————————
TODAY="$(date +"%Y-%m-%d")"
NOW="$(date +"%H-%M-%S")"
LOG_DIR="$HOME/.logs/$TODAY/$NOW"
LOG_FILE="$LOG_DIR/log.txt"
mkdir -p "$LOG_DIR"

# ————————————————————————————————————————————————————————————————
# Execute and capture everything
# ————————————————————————————————————————————————————————————————
{
  echo "=== $(date -u +"%Y-%m-%dT%H:%M:%SZ") Starting git-log-push.sh ==="
  echo
  echo "\$ git add ."
  git add .
  echo

  echo "\$ git commit -m \"$commit_msg\""
  git commit -m "$commit_msg"
  echo

  echo "\$ git push"
  git push
  echo

  echo "=== Diff between HEAD~1 and HEAD (side-by-side) ==="
  # If you have 'bat' installed, use it for a colorized diff:
  if command -v bat &>/dev/null; then
    git diff --color=always --word-diff=color - | bat --paging=never --language=diff
  else
    git diff --color=always --word-diff=color | diff-so-fancy --patch
  fi

  echo
  echo "=== Completed at $(date -u +"%Y-%m-%dT%H:%M:%SZ") ==="
} &> "$LOG_FILE"

echo "Success! Log written to $LOG_FILE"

