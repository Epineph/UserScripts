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
#     • a pushed diff formatted via diff-so-fancy (if available)
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
LOG_FILE="$LOG_DIR/log.diff"
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

  echo "=== Pushed diff (HEAD~1 → HEAD) formatted via diff-so-fancy ==="
  # Use diff-so-fancy on the pushed diff, if available
  if command -v diff-so-fancy &>/dev/null; then
    git diff --color=always HEAD~1 HEAD | diff-so-fancy --patch
  else
    git diff --color=always --word-diff=color HEAD~1 HEAD
  fi

  echo
  echo "=== Completed at $(date -u +"%Y-%m-%dT%H:%M:%SZ") ==="
} &> "$LOG_FILE"


echo "Success! Log written to $LOG_FILE"

