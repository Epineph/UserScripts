#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# repo-updated
#
# Show readable update information for the current Git repository.
#
# Output includes:
#   - repository metadata
#   - local latest commit
#   - upstream latest commit, if configured
#   - sync state: ahead / behind / up to date
#
# Date formats:
#   - ISO date:       2024-09-06
#   - Human date:    6th September 2024
#   - Full timestamp: 2024-09-06T12:34:56+02:00
# -----------------------------------------------------------------------------

set -o pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

DO_FETCH=1

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

function show_help() {
  cat <<'EOF'
Usage:
  repo-updated [OPTIONS]

Description:
  Show update information for the current Git repository.

  The script reports the newest local commit, the newest upstream commit if an
  upstream branch is configured, and whether the current branch is ahead, behind,
  both, or up to date.

Options:
  --no-fetch
      Do not refresh remote refs before reporting.

  -h, --help
      Show this help text.

Examples:
  repo-updated

  repo-updated --no-fetch

  cd ~/repos/my-project
  repo-updated

  repo-updated --NO-FETCH

  repo-updated -H

Output date examples:
  Date ISO:       2024-09-06
  Date readable:  6th September 2024
  Timestamp:      2024-09-06T12:34:56+02:00
EOF
}

# -----------------------------------------------------------------------------
# Utility functions
# -----------------------------------------------------------------------------

function die() {
  printf 'repo-updated: %s\n' "$*" >&2
  exit 1
}

function warn() {
  printf 'repo-updated: warning: %s\n' "$*" >&2
}

function lower() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

function ordinal_day() {
  local day="${1#0}"
  local suffix
  local last_digit
  local last_two_digits

  [[ -n "$day" ]] || {
    printf 'unknown'
    return 0
  }

  last_digit=$((day % 10))
  last_two_digits=$((day % 100))

  if ((last_two_digits >= 11 && last_two_digits <= 13)); then
    suffix='th'
  else
    case "$last_digit" in
      1) suffix='st' ;;
      2) suffix='nd' ;;
      3) suffix='rd' ;;
      *) suffix='th' ;;
    esac
  fi

  printf '%s%s' "$day" "$suffix"
}

function month_name() {
  case "$1" in
    01) printf 'January' ;;
    02) printf 'February' ;;
    03) printf 'March' ;;
    04) printf 'April' ;;
    05) printf 'May' ;;
    06) printf 'June' ;;
    07) printf 'July' ;;
    08) printf 'August' ;;
    09) printf 'September' ;;
    10) printf 'October' ;;
    11) printf 'November' ;;
    12) printf 'December' ;;
    *)  printf 'unknown' ;;
  esac
}

function iso_calendar_date() {
  local timestamp="$1"

  if [[ "$timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
    printf '%s' "${timestamp:0:10}"
  else
    printf 'unknown'
  fi
}

function human_calendar_date() {
  local iso_date="$1"
  local year month day

  if [[ ! "$iso_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    printf 'unknown'
    return 0
  fi

  year="${iso_date:0:4}"
  month="${iso_date:5:2}"
  day="${iso_date:8:2}"

  printf '%s %s %s' \
    "$(ordinal_day "$day")" \
    "$(month_name "$month")" \
    "$year"
}

function git_or_empty() {
  git "$@" 2>/dev/null || true
}

function read_commit_fields() {
  local ref="${1:-HEAD}"
  local raw

  raw="$(git log -1 --format='%cI%x1f%h%x1f%an%x1f%s' "$ref" 2>/dev/null)" ||
    return 1

  [[ -n "$raw" ]] || return 1

  printf '%s\n' "$raw"
}

function print_commit_block() {
  local title="$1"
  local ref="$2"
  local raw timestamp hash author subject
  local date_iso date_human

  printf '\n%s\n' "$title"

  raw="$(read_commit_fields "$ref")" || {
    printf '  none\n'
    return 0
  }

  IFS=$'\x1f' read -r timestamp hash author subject <<< "$raw"

  date_iso="$(iso_calendar_date "$timestamp")"
  date_human="$(human_calendar_date "$date_iso")"

  printf '  Date ISO:       %s\n' "$date_iso"
  printf '  Date readable:  %s\n' "$date_human"
  printf '  Timestamp:      %s\n' "$timestamp"
  printf '  Commit:         %s\n' "$hash"
  printf '  Author:         %s\n' "$author"
  printf '  Subject:        %s\n' "$subject"
}

function parse_args() {
  local arg lower_arg

  while (($# > 0)); do
    arg="$1"
    lower_arg="$(lower "$arg")"

    case "$lower_arg" in
      -h|--help)
        show_help
        exit 0
        ;;
      --no-fetch)
        DO_FETCH=0
        ;;
      *)
        show_help >&2
        die "unknown option: $arg"
        ;;
    esac

    shift
  done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

function main() {
  local root repo branch upstream remote remote_url fetch_state
  local sync_status ahead behind

  parse_args "$@"

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die 'not inside a Git repository'
  fi

  root="$(git rev-parse --show-toplevel)"
  repo="$(basename "$root")"
  branch="$(git branch --show-current 2>/dev/null)"
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name \
    '@{u}' 2>/dev/null || true)"

  [[ -n "$branch" ]] || branch='detached HEAD'

  if [[ -n "$upstream" ]]; then
    remote="${upstream%%/*}"
    remote_url="$(git_or_empty remote get-url "$remote")"
  else
    remote_url="$(git_or_empty remote get-url origin)"
  fi

  fetch_state='not run'

  if [[ -n "$upstream" && "$DO_FETCH" -eq 1 ]]; then
    if git fetch --quiet; then
      fetch_state='ok'
    else
      fetch_state='failed; using cached remote refs'
      warn 'git fetch failed; reporting from cached refs'
    fi
  elif [[ "$DO_FETCH" -eq 0 ]]; then
    fetch_state='skipped'
  fi

  printf '\nRepository\n'
  printf '  Name:      %s\n' "$repo"
  printf '  Path:      %s\n' "$root"
  printf '  Branch:    %s\n' "$branch"
  printf '  Remote:    %s\n' "${remote_url:-none}"
  printf '  Fetch:     %s\n' "$fetch_state"

  print_commit_block 'Local latest commit' 'HEAD'

  if [[ -z "$upstream" ]]; then
    printf '\nUpstream\n'
    printf '  none configured\n\n'
    exit 0
  fi

  printf '\nUpstream\n'
  printf '  Branch:    %s\n' "$upstream"

  print_commit_block 'Remote latest commit' "$upstream"

  sync_status="$(git rev-list --left-right --count \
    "HEAD...$upstream" 2>/dev/null || true)"

  printf '\nSync\n'

  if [[ -z "$sync_status" ]]; then
    printf '  Status:    unknown\n'
    printf '  Ahead:     unknown\n'
    printf '  Behind:    unknown\n\n'
    exit 0
  fi

  ahead="${sync_status%%[[:space:]]*}"
  behind="${sync_status##*[[:space:]]}"

  printf '  Ahead:     %s\n' "$ahead"
  printf '  Behind:    %s\n' "$behind"

  if [[ "$ahead" -eq 0 && "$behind" -eq 0 ]]; then
    printf '  Status:    up to date\n'
  elif [[ "$ahead" -eq 0 ]]; then
    printf '  Status:    behind by %s commit(s)\n' "$behind"
  elif [[ "$behind" -eq 0 ]]; then
    printf '  Status:    ahead by %s commit(s)\n' "$ahead"
  else
    printf '  Status:    ahead by %s commit(s), behind by %s commit(s)\n' \
      "$ahead" "$behind"
  fi

  printf '\n'
}

main "$@"
