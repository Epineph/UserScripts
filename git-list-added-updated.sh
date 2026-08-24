#!/usr/bin/env bash
#
# git-list-added.sh - List files with the date they first entered a Git repo
#
# SYNOPSIS
#   git-list-added.sh [OPTIONS] [PATH...]
#
# DESCRIPTION
#   For each file under version control (in the specified PATHs, or . by
#   default), show the date of the commit in which it was introduced.
#
#   Output is sorted chronologically (oldest additions first) unless another
#   order is selected. Dates use strict ISO 8601 format:
#   YYYY-MM-DDTHH:MM:SS+HH:MM.
#
# OPTIONS
#   -s, --sort ORDER     sort by: oldest, newest, name, or name-desc
#                        (default: oldest)
#   -r, --reverse        compatibility alias for --sort newest
#       --newest         convenience alias for --sort newest
#       --oldest         convenience alias for --sort oldest
#   -n, --number INTEGER show the first positive INTEGER results after sorting
#   -h, --help           display this help and exit
#
# REQUIREMENTS
#   - Bash
#   - Git 2.x or newer
#   - Coreutils: sort, tail
#   - POSIX awk
#
# EXAMPLES
#   # List all tracked files, oldest additions first:
#   ./git-list-added.sh
#
#   # List files under src/, newest first:
#   ./git-list-added.sh --sort newest src
#
#   # The shorter, backward-compatible equivalent:
#   ./git-list-added.sh -r src
#
#   # List the 10 newest files under src/ and tests/:
#   ./git-list-added.sh --sort newest -n 10 src tests
#
#   # List five tracked files in descending filename order:
#   ./git-list-added.sh --sort name-desc --number 5
#
#   # Treat a path beginning with a hyphen as a path, not an option:
#   ./git-list-added.sh -- -generated
#
#   # Install as a global command:
#   chmod +x git-list-added.sh
#   sudo mv git-list-added.sh /usr/local/bin/git-list-added
#
################################################################################

set -euo pipefail

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

function show_help()
{
  awk '
    NR < 4 { next }
    /^#{80}$/ { exit }
    { sub(/^# ?/, ""); print }
  ' "$0"
}

function die()
{
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function require_option_value()
{
  local option=$1
  local remaining=$2

  ((remaining >= 2)) || die "$option requires a value."
}

function validate_sort_order()
{
  case "$1" in
    oldest|newest|name|name-desc)
      ;;
    *)
      die "invalid sort order '$1'; use oldest, newest, name, or name-desc."
      ;;
  esac
}

function validate_number()
{
  [[ "$1" =~ ^[1-9][0-9]*$ ]] ||
    die "--number requires a positive integer; received '$1'."
}

function collect_additions()
{
  local addition
  local date_added
  local file
  local timestamp

  # NUL-delimited input prevents word splitting while tracked paths are read.
  git ls-files -z -- "${PATHS[@]}" |
    while IFS= read -r -d '' file; do
      # --diff-filter=A : retain commits in which the path was added
      # %ct             : Unix timestamp, used for timezone-safe sorting
      # %cI             : strict ISO 8601 committer date, shown to the user
      addition=$(git log --diff-filter=A \
        --format='%ct%x09%cI' -- "$file" | tail -n 1)

      # A tracked file should have an addition commit, but skip it safely if its
      # history cannot be resolved (for example, in unusual shallow histories).
      [[ "$addition" == *$'\t'* ]] || continue

      timestamp=${addition%%$'\t'*}
      date_added=${addition#*$'\t'}
      printf '%s\t%s\t%s\n' "$timestamp" "$date_added" "$file"
    done
}

function format_output()
{
  local limit=$1

  # Remove the internal timestamp. An empty limit means no limit.
  awk -v limit="$limit" '
    limit == "" || NR <= limit {
      sub(/^[^\t]*\t/, "")
      print
    }
  '
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

SORT_ORDER='oldest'
NUMBER=''
PATHS=()

while (($#)); do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    -r|--reverse|--newest)
      SORT_ORDER='newest'
      shift
      ;;
    --oldest)
      SORT_ORDER='oldest'
      shift
      ;;
    -s|--sort)
      require_option_value "$1" "$#"
      SORT_ORDER=$2
      shift 2
      ;;
    --sort=*)
      SORT_ORDER=${1#*=}
      shift
      ;;
    -n|--number)
      require_option_value "$1" "$#"
      NUMBER=$2
      validate_number "$NUMBER"
      shift 2
      ;;
    --number=*)
      NUMBER=${1#*=}
      validate_number "$NUMBER"
      shift
      ;;
    -n?*)
      NUMBER=${1#-n}
      validate_number "$NUMBER"
      shift
      ;;
    --)
      shift
      PATHS+=("$@")
      break
      ;;
    -*)
      die "unknown option '$1'."
      ;;
    *)
      PATHS+=("$1")
      shift
      ;;
  esac
done

validate_sort_order "$SORT_ORDER"

((${#PATHS[@]} > 0)) || PATHS=(.)

# -----------------------------------------------------------------------------
# Repository checks and output
# -----------------------------------------------------------------------------

git rev-parse --is-inside-work-tree &>/dev/null ||
  die 'not inside a Git working tree.'

SORT_OPTIONS=(-t $'\t')

case "$SORT_ORDER" in
  oldest)
    SORT_OPTIONS+=(-k1,1n -k3,3)
    ;;
  newest)
    SORT_OPTIONS+=(-k1,1nr -k3,3)
    ;;
  name)
    SORT_OPTIONS+=(-k3,3 -k1,1n)
    ;;
  name-desc)
    SORT_OPTIONS+=(-k3,3r -k1,1n)
    ;;
esac

collect_additions |
  LC_ALL=C sort "${SORT_OPTIONS[@]}" |
  format_output "$NUMBER"

exit 0
