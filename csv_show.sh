#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# csv-preview
# -----------------------------------------------------------------------------
# Display CSV files either as pretty tables using Miller, or as raw CSV bytes.
# -----------------------------------------------------------------------------

readonly SCRIPT_NAME="$(basename "$0")"

TARGET="table"
INPUTS=()

BAT_ARGS_DEFAULT=(
  --style="grid,header,snip"
  --italic-text="always"
  --theme="gruvbox-dark"
  --squeeze-blank
  --squeeze-limit="2"
  --force-colorization
  --terminal-width="-1"
  --tabs="2"
  --paging="never"
  --chop-long-lines
)

# If BAT_CSV_ARGS is supplied, split it on whitespace.
# This intentionally avoids eval.
if [[ -n "${BAT_CSV_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  BAT_ARGS=(${BAT_CSV_ARGS})
else
  BAT_ARGS=("${BAT_ARGS_DEFAULT[@]}")
fi

function have() {
  command -v "$1" >/dev/null 2>&1
}

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function print_help() {
  cat <<EOF
${SCRIPT_NAME} — Display CSV as a pretty table or raw bytes.

Usage:
  ${SCRIPT_NAME} [OPTIONS] [INPUT.csv ...]
  command | ${SCRIPT_NAME} [OPTIONS] -

Options:
  -t, --target {table|csv}
      Presentation target.

      table  Pretty table using Miller. This is the default.
      csv    Raw CSV bytes, like cat.

  -h, --help
      Show this help text and exit.

Environment:
  BAT_CSV_ARGS
      Optional extra/alternative flags passed to bat in table mode.

Examples:
  ${SCRIPT_NAME} data.csv
  ${SCRIPT_NAME} -t table data.csv
  ${SCRIPT_NAME} -t csv data.csv
  ${SCRIPT_NAME} -t table ../*.csv
  mlr --icsv filter '\$age > 70' data.csv | ${SCRIPT_NAME} -t table -
  mlr --icsv filter '\$age > 70' data.csv | ${SCRIPT_NAME} -t csv -

Requirements:
  table mode:
    - mlr
    - bat optional; plain Miller output is used if bat is unavailable

  csv mode:
    - cat only

Exit codes:
  0  success
  1  usage or input error
  2  missing dependency
  3  processing failure
EOF
}

function parse_args() {
  while (($#)); do
    case "$1" in
      -h | --help)
        print_help
        exit 0
        ;;

      -t | --target)
        [[ $# -ge 2 ]] || die "Missing value after $1"
        TARGET="$2"
        shift 2

        case "$TARGET" in
          table | csv) ;;
          *) die "Invalid target '${TARGET}'. Use 'table' or 'csv'." ;;
        esac
        ;;

      --)
        shift
        while (($#)); do
          INPUTS+=("$1")
          shift
        done
        ;;

      -*)
        die "Unknown option: $1"
        ;;

      *)
        INPUTS+=("$1")
        shift
        ;;
    esac
  done
}

function validate_inputs() {
  if ((${#INPUTS[@]} == 0)); then
    if [[ ! -t 0 ]]; then
      INPUTS=("-")
    else
      die "No input provided. Pass a file path or '-' for stdin."
    fi
  fi

  local input

  for input in "${INPUTS[@]}"; do
    if [[ "$input" != "-" && ! -r "$input" ]]; then
      die "Cannot read input file: $input"
    fi
  done
}

function print_file_header() {
  local input="$1"

  if ((${#INPUTS[@]} > 1)); then
    printf '\n==> %s <==\n' "$input"
  fi
}

function show_table_one() {
  local input="$1"

  print_file_header "$input"

  if [[ "$input" == "-" ]]; then
    if have bat; then
      mlr --icsv --opprint cat | bat "${BAT_ARGS[@]}" || return 3
    else
      mlr --icsv --opprint cat || return 3
    fi
  else
    if have bat; then
      mlr --icsv --opprint cat "$input" | bat "${BAT_ARGS[@]}" || return 3
    else
      mlr --icsv --opprint cat "$input" || return 3
    fi
  fi
}

function show_table() {
  have mlr || {
    printf 'Missing dependency: miller executable "mlr" is required.\n' >&2
    exit 2
  }

  local input

  for input in "${INPUTS[@]}"; do
    show_table_one "$input" || exit 3
  done
}

function show_csv() {
  local input

  for input in "${INPUTS[@]}"; do
    if [[ "$input" == "-" ]]; then
      cat || exit 3
    else
      cat -- "$input" || exit 3
    fi
  done
}

function main() {
  parse_args "$@"
  validate_inputs

  case "$TARGET" in
    table) show_table ;;
    csv) show_csv ;;
  esac
}

main "$@"
