#!/bin/ash
# -----------------------------------------------------------------------------
# apk-install.sh -- Select packages by line number from saved apk search results.
#
# Target: Alpine Linux, including the live ISO and BusyBox ash.
# Requires: BusyBox ash, awk, cat; apk and BusyBox id for installation.
# Style: two-space indentation; maximum line width of 81 columns.
#
# Run this file as a script; do not source it into your current shell.
# -----------------------------------------------------------------------------

# Disable pathname expansion during deliberate splitting of lists below.
set -f
LC_ALL=C
export LC_ALL

# --- Help and diagnostics ------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  apk-install.sh -f FILE SELECTORS [--show] [-i | --install] [OPTIONS]

Selectors (repeat or combine; line numbers start at 1):
  --range N:N          Select an inclusive range.
  --from N --to N      Another spelling of --range N:N.
  --lines LIST...     Accept commas, spaces, and ranges: 2,5 8:12.

Actions:
  --show              Print package names. This is the default action.
  -i, --interactive   Print names, then ask before installing.
  --install           Install directly; may be combined with --show.

Options:
  -f, --file FILE     Read a saved, unnumbered apk search results file.
  --names             Input already contains names from apk search -q.
  --offline           Install with apk --no-network, using local packages.
  -h, --help          Show this help.
  --long-help         Show help, examples, and input rules.

Examples:
  apk-install.sh -f list.txt --range 240:280 --show
  apk-install.sh -f list.txt --from 240 --to 280 -i
  apk-install.sh -f list.txt --lines 240,242 250:260 --show --install

The -i option means interactive. It is not an alias for --install.
EOF
}

long_help() {
  usage
  cat <<'EOF'

Input:
  apk search dev > list.txt
  apk-install.sh -f list.txt --range 1:10 -i

  Alternatively, avoid version stripping altogether:
  apk search -q dev > names.txt
  apk-install.sh -f names.txt --names --lines 1,3 5:8 -i

Rules:
  * Default input: one name-version-rN per line, without descriptions.
  * --names input: one package name per line, without version stripping.
  * Leading/trailing whitespace and Windows CRLF line endings are accepted.
  * A selected blank line, malformed entry, or line beyond EOF is an error.
  * Line numbers must be in 1..999999999; leading zeros are decimal.
  * Repeated/overlapping selections and duplicate packages are deduplicated.
  * Output follows the original file order, not the order of selectors.
  * All input is checked before any package names are printed or installed.
  * Selected names go to one apk add call, with normal dependency handling.
  * Versions are not pinned: apk chooses versions from configured repositories.
  * --offline needs cached/local packages, indexes, and their dependencies.
  * This script does not update indexes or run lbu commit automatically.

Preview needs no root privileges. Installation requires root.
Exit codes: 0 success/cancellation, 1 input error, 2 usage/setup error.
When apk runs, its exit status is returned unchanged.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 2
}

# --- Selector parsing ----------------------------------------------------------

normalise_number() {
  # Return a validated decimal number in the global variable "number".
  case "$1" in
    ''|*[!0-9]*) die "invalid line number: $1" ;;
  esac
  number=$1
  while [ "${number#0}" != "$number" ]; do
    number=${number#0}
  done
  if [ -z "$number" ] || [ "${#number}" -gt 9 ]; then
    die "line number must be in 1..999999999: $1"
  fi
}

add_selector() {
  local first last
  case "$1" in
    *:*:*) die "invalid selector: $1" ;;
    *:*)
      normalise_number "${1%%:*}"
      first=$number
      normalise_number "${1#*:}"
      last=$number
      ;;
    *)
      normalise_number "$1"
      first=$number
      last=$number
      ;;
  esac
  [ "$last" -ge "$first" ] || die "range is reversed: $1"
  selectors="${selectors}${selectors:+ }$first:$last"
}

add_lines() {
  local item
  # These delimiters are space, comma, tab, and newline, respectively.
  local IFS=' ,	
'
  # Intentional splitting; globbing is disabled with set -f above.
  # shellcheck disable=SC2086
  set -- $1
  [ "$#" -gt 0 ] || die "--lines needs at least one selector"
  for item do
    add_selector "$item"
  done
}

# --- Command-line options ------------------------------------------------------

file=
selectors=
from=
to=
show=0
mode=show
names=0
offline=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --long-help) long_help; exit 0 ;;
    -f|--file)
      [ "$#" -ge 2 ] || die "$1 needs a file path"
      [ -z "$file" ] || die "specify --file only once"
      file=$2
      shift 2
      ;;
    --range)
      [ "$#" -ge 2 ] || die "--range needs N:N"
      case "$2" in
        *:*) add_selector "$2" ;;
        *) die "--range needs N:N" ;;
      esac
      shift 2
      ;;
    --from|--to)
      [ "$#" -ge 2 ] || die "$1 needs a line number"
      normalise_number "$2"
      case "$1" in
        --from)
          [ -z "$from" ] || die "specify --from only once"
          from=$number
          ;;
        --to)
          [ -z "$to" ] || die "specify --to only once"
          to=$number
          ;;
      esac
      shift 2
      ;;
    --lines)
      shift
      [ "$#" -gt 0 ] || die "--lines needs selectors"
      case "$1" in -*) die "--lines needs selectors" ;; esac
      while [ "$#" -gt 0 ]; do
        case "$1" in -*) break ;; esac
        add_lines "$1"
        shift
      done
      ;;
    --show) show=1; shift ;;
    -i|--interactive)
      [ "$mode" != install ] || die "choose --interactive OR --install"
      mode=interactive
      shift
      ;;
    --install)
      [ "$mode" != interactive ] || die "choose --interactive OR --install"
      mode=install
      shift
      ;;
    --names) names=1; shift ;;
    --offline) offline=1; shift ;;
    *) die "unknown argument: $1 (use --help)" ;;
  esac
done

[ -n "$file" ] || die "specify a file with -f (use --help)"
if [ ! -f "$file" ] || [ ! -r "$file" ]; then
  die "not a readable regular file: $file"
fi
command -v awk >/dev/null 2>&1 || die "awk is required (BusyBox awk is enough)"

if [ -n "$from" ] || [ -n "$to" ]; then
  if [ -z "$from" ] || [ -z "$to" ]; then
    die "use both --from and --to"
  fi
  add_selector "$from:$to"
fi
[ -n "$selectors" ] || die "select lines with --range, --from/--to, or --lines"

# --- Extract and validate before displaying or installing anything -------------

# Read through stdin so filenames like "-list" and "x=y" are handled literally.
# The shell captures output; an awk failure prevents partial output being used.
packages=$(awk -v selectors="$selectors" -v names="$names" '
  BEGIN {
    count = split(selectors, selected, " ")
    for (i = 1; i <= count; i++) {
      split(selected[i], bounds, ":")
      first[i] = bounds[1] + 0
      last[i] = bounds[2] + 0
    }
  }
  {
    use_line = 0
    for (i = 1; i <= count; i++) {
      if (NR >= first[i] && NR <= last[i]) {
        use_line = 1
        break
      }
    }
    if (!use_line) next

    package = $0
    sub(/^[[:space:]]+/, "", package)
    sub(/[[:space:]]+$/, "", package)

    if (!names && !sub(/-[0-9][A-Za-z0-9._+~]*-r[0-9]+$/, "", package)) {
      printf "Error: line %d is not name-version-rN.\n", NR > "/dev/stderr"
      bad = 1
      next
    }
    if (package !~ /^[A-Za-z0-9][A-Za-z0-9+_.-]*$/) {
      printf "Error: line %d has an invalid package name.\n", NR > "/dev/stderr"
      bad = 1
      next
    }
    if (!seen[package]++) print package
  }
  END {
    for (i = 1; i <= count; i++) {
      if (last[i] > NR) {
        printf "Error: selector %s exceeds %d lines.\n", selected[i], NR \
          > "/dev/stderr"
        bad = 1
      }
    }
    if (bad) exit 1
  }
' < "$file") || exit 1

[ -n "$packages" ] || die "no packages found in the selected lines"

# --- Preview, optional confirmation, and one apk operation ---------------------

if [ "$show" -eq 1 ] || [ "$mode" != install ]; then
  printf '%s\n' "$packages"
fi
[ "$mode" != show ] || exit 0

command -v apk >/dev/null 2>&1 || die "apk was not found"
[ "$(id -u)" = 0 ] || die "installation requires root"

if [ "$mode" = interactive ]; then
  printf 'Install these packages? [y/N] ' >&2
  if ! IFS= read -r answer; then
    printf '\nNo answer received; installation cancelled.\n' >&2
    exit 1
  fi
  case "$answer" in
    [yY]|[yY][eE][sS]) ;;
    *) printf 'Installation cancelled.\n' >&2; exit 0 ;;
  esac
fi

# Names are validated, contain no whitespace, and globbing remains disabled.
# shellcheck disable=SC2086
set -- $packages
printf 'Installing %s selected package(s).\n' "$#" >&2
if [ "$offline" -eq 1 ]; then
  exec apk --no-network add -- "$@"
fi
exec apk add -- "$@"
