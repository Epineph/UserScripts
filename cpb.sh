#!/usr/bin/env bash
#
# cpb - copy one file, preserving an overwritten destination as a backup
#
# The destination may be an existing directory or a complete output pathname.
# A replacement is staged in the destination directory before the old file is
# moved, reducing the chance of leaving a partial destination after a failure.

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
readonly PROGRAM_VERSION="1.0.0"

target=""
destination=""
destination_argument=""
backup_mode="auto"
suffix=""
suffix_was_set=false
verbose=false
dry_run=false

temporary_directory=""
temporary_payload=""
backup_path=""
destination_path=""
original_was_moved=false
copy_was_committed=false

# -----------------------------------------------------------------------------
# Messages and help
# -----------------------------------------------------------------------------

function print_error() {
  printf '%s: error: %s\n' "$PROGRAM_NAME" "$*" >&2
}

function die() {
  print_error "$*"
  exit 1
}

function print_help() {
  cat <<'EOF'
Usage:
  cpb [OPTIONS] SOURCE DESTINATION
  cpb [OPTIONS] -t SOURCE -d DESTINATION

Copy one file and preserve an overwritten destination as a backup.

Path options:
  -t, --target, --target-file FILE
                              File to copy
  -d, --destination PATH     Existing directory or complete output pathname

Backup options:
      --backup[=MODE]        Back up an existing destination; MODE is auto,
                              simple, numbered, or none (default: auto)
      --no-backup            Overwrite without retaining the previous file
      --suffix SUFFIX        Backup suffix; a leading dot is added if omitted

Output options:
  -v, --verbose              Show resolution and backup details
  -n, --dry-run              Show the planned transformation without changing
                              anything
  -h, --help                 Show this help and exit
      --version              Show version information and exit

Destination rules:
  * If DESTINATION is an existing directory, the result is
    DESTINATION/basename(SOURCE).
  * Otherwise, DESTINATION is the complete pathname of the copied file. Its
    parent directory must already exist.
  * Unrelated files in the destination directory are never modified.

Backup rules:
  auto      Use DESTINATION.bak, or DESTINATION.bak-N if a collision exists.
  simple    Use the requested suffix, but add -N rather than overwrite an
            existing backup. The default suffix is .bak.
  numbered  Always use a numbered suffix. The default starts at .bak-1.
  none      Do not retain the overwritten destination.

For numbered mode, a custom suffix without a trailing number starts at -1:
  --backup=numbered --suffix=old  ->  DESTINATION.old-1

Examples:
  cpb settings.conf ~/.config/app/settings.conf
  cpb -t settings.conf -d ~/.config/app/
  cpb --backup=simple --suffix=old SOURCE DESTINATION
  cpb --backup=numbered --suffix=.previous SOURCE DESTINATION
  cpb --dry-run --verbose SOURCE DESTINATION
EOF
}

# -----------------------------------------------------------------------------
# Path and backup helpers
# -----------------------------------------------------------------------------

function path_exists() {
  [[ -e $1 || -L $1 ]]
}

function quote_path() {
  printf '%q' "$1"
}

function normalise_suffix() {
  local value=$1

  [[ -n $value ]] || die "--suffix cannot be empty"

  if [[ $value == .* ]]; then
    suffix=$value
  else
    suffix=".${value}"
  fi
}

function next_available_numbered_path() {
  local prefix=$1
  local number=$2
  local candidate

  while :; do
    candidate="${prefix}${number}"

    if ! path_exists "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi

    ((number += 1))
  done
}

function select_backup_path() {
  local base
  local number_prefix
  local first_number

  case $backup_mode in
    auto | simple)
      base="${destination_path}${suffix}"

      if ! path_exists "$base"; then
        backup_path=$base
      else
        backup_path=$(next_available_numbered_path "${base}-" 1)
      fi
      ;;

    numbered)
      if [[ $suffix =~ ^(.*[^0-9])([0-9]+)$ ]]; then
        number_prefix="${destination_path}${BASH_REMATCH[1]}"
        first_number=$((10#${BASH_REMATCH[2]}))
      else
        number_prefix="${destination_path}${suffix}-"
        first_number=1
      fi

      backup_path=$(next_available_numbered_path \
        "$number_prefix" "$first_number")
      ;;

    none)
      backup_path=""
      ;;

    *)
      die "internal error: unsupported backup mode: $backup_mode"
      ;;
  esac
}

function resolve_destination() {
  local source_name=${target##*/}
  local parent_directory
  local destination_name

  destination_argument=$destination

  if [[ -d $destination ]]; then
    destination_path="${destination%/}/${source_name}"
  else
    if [[ $destination == */ ]]; then
      die "destination ends in '/' but is not an existing directory: "\
"$(quote_path "$destination")"
    fi

    destination_path=$destination
  fi

  parent_directory=${destination_path%/*}
  destination_name=${destination_path##*/}

  if [[ $parent_directory == "$destination_path" ]]; then
    parent_directory="."
  elif [[ -z $parent_directory ]]; then
    parent_directory="/"
  fi

  [[ -n $destination_name ]] || die "destination filename is empty"
  [[ $destination_name != . && $destination_name != .. ]] || \
    die "destination must name a file, not '$destination_name'"
  [[ -d $parent_directory ]] || \
    die "destination directory does not exist: "\
"$(quote_path "$parent_directory")"

  if path_exists "$destination_path" && \
    [[ ! -f $destination_path && ! -L $destination_path ]]; then
    die "destination is not a regular file or symbolic link: "\
"$(quote_path "$destination_path")"
  fi

  if path_exists "$destination_path" && [[ $target -ef $destination_path ]]; then
    die "source and resolved destination are the same file"
  fi
}

# -----------------------------------------------------------------------------
# Transaction cleanup and reporting
# -----------------------------------------------------------------------------

function cleanup() {
  local exit_status=$?

  trap - EXIT HUP INT TERM

  if [[ $original_was_moved == true && $copy_was_committed == false ]]; then
    if ! path_exists "$destination_path" && path_exists "$backup_path"; then
      if mv -T -- "$backup_path" "$destination_path"; then
        print_error "copy failed; restored the original destination"
        original_was_moved=false
      else
        print_error "copy failed; original remains at "\
"$(quote_path "$backup_path")"
      fi
    else
      print_error "copy failed; original remains at "\
"$(quote_path "$backup_path")"
    fi
  fi

  if [[ -n $temporary_payload ]]; then
    rm -f -- "$temporary_payload"
  fi

  if [[ -n $temporary_directory ]]; then
    rmdir -- "$temporary_directory" 2>/dev/null || true
  fi

  exit "$exit_status"
}

function report_plan_or_result() {
  local state=$1
  local destination_existed=$2

  if [[ $verbose == true ]]; then
    printf '%s:\n' "$PROGRAM_NAME"
    printf '  state:                %s\n' "$state"
    printf '  source:               %s\n' "$(quote_path "$target")"
    printf '  destination argument: %s\n' \
      "$(quote_path "$destination_argument")"
    printf '  resolved destination: %s\n' \
      "$(quote_path "$destination_path")"
    printf '  destination existed:  %s\n' "$destination_existed"
    printf '  backup mode:           %s\n' "$backup_mode"

    if [[ -n $backup_path ]]; then
      printf '  backup path:           %s\n' "$(quote_path "$backup_path")"
    else
      printf '  backup path:           none\n'
    fi
  else
    printf '%s: %s -> %s' \
      "$PROGRAM_NAME" \
      "$(quote_path "$target")" \
      "$(quote_path "$destination_path")"

    if [[ -n $backup_path ]]; then
      printf ' [backup: %s]' "$(quote_path "$backup_path")"
    fi

    if [[ $state == planned ]]; then
      printf ' [dry run]'
    fi

    printf '\n'
  fi
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

function require_option_value() {
  local option=$1
  local remaining=$2

  ((remaining >= 2)) || die "$option requires an argument"
}

function set_target() {
  [[ -n $1 ]] || die "--target cannot be empty"
  [[ -z $target ]] || die "source file was specified more than once"
  target=$1
}

function set_destination() {
  [[ -n $1 ]] || die "--destination cannot be empty"
  [[ -z $destination ]] || die "destination was specified more than once"
  destination=$1
}

function parse_arguments() {
  local -a positional=()
  local value

  while (($# > 0)); do
    case $1 in
      -t | --target | --target-file)
        require_option_value "$1" "$#"
        set_target "$2"
        shift 2
        ;;

      --target=* | --target-file=*)
        set_target "${1#*=}"
        shift
        ;;

      -d | --destination)
        require_option_value "$1" "$#"
        set_destination "$2"
        shift 2
        ;;

      --destination=*)
        set_destination "${1#*=}"
        shift
        ;;

      --backup | -b)
        backup_mode="auto"
        shift
        ;;

      --backup=auto | --backup=simple | --backup=numbered)
        backup_mode=${1#*=}
        shift
        ;;

      --backup=none | --no-backup)
        backup_mode="none"
        shift
        ;;

      --backup=*)
        value=${1#*=}
        die "invalid backup mode: $value"
        ;;

      -s | --suffix)
        require_option_value "$1" "$#"
        normalise_suffix "$2"
        suffix_was_set=true
        shift 2
        ;;

      --suffix=*)
        normalise_suffix "${1#*=}"
        suffix_was_set=true
        shift
        ;;

      -v | --verbose)
        verbose=true
        shift
        ;;

      -n | --dry-run)
        dry_run=true
        shift
        ;;

      -h | --help)
        print_help
        exit 0
        ;;

      --version)
        printf '%s %s\n' "$PROGRAM_NAME" "$PROGRAM_VERSION"
        exit 0
        ;;

      --)
        shift
        positional+=("$@")
        break
        ;;

      -*)
        die "unknown option: $1"
        ;;

      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  for value in "${positional[@]}"; do
    if [[ -z $target ]]; then
      target=$value
    elif [[ -z $destination ]]; then
      destination=$value
    else
      die "too many positional arguments"
    fi
  done

  [[ -n $target ]] || die "missing source file"
  [[ -n $destination ]] || die "missing destination"
}

# -----------------------------------------------------------------------------
# Copy transaction
# -----------------------------------------------------------------------------

function move_original_to_available_backup() {
  local attempts=0

  while :; do
    select_backup_path
    ((attempts += 1))

    ((attempts <= 10000)) || \
      die "could not reserve a collision-free backup pathname"

    mv --no-clobber --no-target-directory -- \
      "$destination_path" "$backup_path"

    if ! path_exists "$destination_path"; then
      original_was_moved=true
      return 0
    fi

    # A backup appeared between selection and the no-clobbering rename.
    # Select another name and retry without touching either existing file.
  done
}

function perform_copy() {
  local destination_directory
  local destination_existed=false

  if path_exists "$destination_path"; then
    destination_existed=true
  fi

  if [[ $destination_existed == true && $backup_mode != none ]]; then
    select_backup_path
  else
    backup_path=""
  fi

  if [[ $dry_run == true ]]; then
    report_plan_or_result "planned" "$destination_existed"
    return 0
  fi

  destination_directory=${destination_path%/*}
  if [[ $destination_directory == "$destination_path" ]]; then
    destination_directory="."
  elif [[ -z $destination_directory ]]; then
    destination_directory="/"
  fi

  temporary_directory=$(mktemp -d \
    --tmpdir="$destination_directory" '.cpb.XXXXXXXXXX')
  temporary_payload="${temporary_directory}/payload"

  cp -- "$target" "$temporary_payload"

  # Re-evaluate after staging. A destination created while the source was being
  # copied must receive the same protection as one that existed initially.
  destination_existed=false
  backup_path=""

  if path_exists "$destination_path"; then
    destination_existed=true
  fi

  if [[ $destination_existed == true && $backup_mode != none ]]; then
    move_original_to_available_backup
  fi

  mv --force --no-target-directory -- \
    "$temporary_payload" "$destination_path"
  temporary_payload=""
  copy_was_committed=true

  rmdir -- "$temporary_directory"
  temporary_directory=""

  report_plan_or_result "copied" "$destination_existed"
}

function main() {
  parse_arguments "$@"

  [[ -f $target ]] || die "source is not a readable regular file: "\
"$(quote_path "$target")"
  [[ -r $target ]] || die "source is not readable: $(quote_path "$target")"

  if [[ $suffix_was_set == false ]]; then
    case $backup_mode in
      numbered)
        suffix=".bak-1"
        ;;

      *)
        suffix=".bak"
        ;;
    esac
  fi

  resolve_destination
  perform_copy
}

trap cleanup EXIT HUP INT TERM
main "$@"
