#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

PROGRAM_NAME="$(basename "$0")"

TARGET_STRING=""
TARGET_FILE=""
TARGET_DIR=""
TARGET_PATH=""
POSITIONAL_INPUT=""

DO_FILE_CONTENTS=0
DO_FILE_NAME=0
LINE_SPEC=""
OUTPUT_PATH=""
DUPLICATE=0

function print_help() {
  cat <<'EOF'
Usage:
  space-to-underscore.sh [options] [string-or-path]

Purpose:
  Convert literal space characters ( ) to underscores (_) in:
    - a string
    - a file name
    - selected lines in a file
    - a directory name

Notes:
  - If a positional argument is given and it exists as a path, it is treated as
    a filesystem target. Otherwise, it is treated as a plain string.
  - If a file target is given but neither --file-name nor --file-contents is
    specified, the script prompts for: name, contents, or both.
  - For file contents, line selection is optional. Without --line-numbers, all
    lines are transformed.
  - By default, file-content changes are applied in place.
  - --duplicate creates a copy with enumeration instead of overwriting.
  - --output writes or moves the result elsewhere.

Options:
  -s, --string VALUE         Treat VALUE as a string and print transformed text.
  -f, --file PATH            Explicitly target a file.
  -d, --dir PATH             Explicitly target a directory name.
  -t, --target PATH          Auto-detect file vs directory from PATH.
      --file-contents        Transform file contents.
      --file-name            Transform only the file name.
  -l, --line-numbers SPEC    Apply content changes only to selected lines.
                             Example: "1,3,6,8-30,34"
  -o, --output PATH          Output file/path or output directory.
      --duplicate            Write to a duplicate with enumeration.
  -h, --help                 Show this help text.

Examples:
  space-to-underscore.sh "a b c"
  space-to-underscore.sh -s "alpha beta gamma"
  space-to-underscore.sh -f "./my file.txt" --file-name
  space-to-underscore.sh -f "./my file.txt" --file-contents
  space-to-underscore.sh -f "./my file.txt" --file-contents \
    --line-numbers "1,3,8-12"
  space-to-underscore.sh -f "./my file.txt" --file-name \
    --file-contents --duplicate
  space-to-underscore.sh -d "./my directory"
  space-to-underscore.sh -t "./my file.txt"
EOF
}

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function note() {
  printf '%s\n' "$*" >&2
}

function replace_spaces() {
  local input="$1"
  printf '%s' "${input// /_}"
}

function trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

function validate_line_spec() {
  local spec="$1"
  local token=""
  local start=""
  local end=""
  local cleaned=""

  cleaned="${spec//[[:space:]]/}"
  [[ -n "$cleaned" ]] || die "--line-numbers was given an empty value"

  IFS=',' read -r -a __line_tokens <<< "$cleaned"
  for token in "${__line_tokens[@]}"; do
    [[ -n "$token" ]] || die "invalid empty token in line specification"

    if [[ "$token" =~ ^[0-9]+$ ]]; then
      (( token >= 1 )) || die "line numbers must be >= 1: $token"
      continue
    fi

    if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      (( start >= 1 )) || die "range start must be >= 1: $token"
      (( end >= start )) || die "range end must be >= start: $token"
      continue
    fi

    die "invalid line token: $token"
  done
}

function prompt_file_mode_if_needed() {
  local path="$1"
  local reply=""

  if (( DO_FILE_CONTENTS == 1 || DO_FILE_NAME == 1 )); then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    die "file target '$path' needs --file-name and/or --file-contents in " \
      "non-interactive mode"
  fi

  printf 'File target: %s\n' "$path" >&2
  printf 'Transform [n]ame, [c]ontents, or [b]oth? ' >&2
  read -r reply
  reply="$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')"
  reply="$(trim_whitespace "$reply")"

  case "$reply" in
    n|name)
      DO_FILE_NAME=1
      ;;
    c|contents)
      DO_FILE_CONTENTS=1
      ;;
    b|both)
      DO_FILE_NAME=1
      DO_FILE_CONTENTS=1
      ;;
    *)
      die "invalid selection: '$reply'"
      ;;
  esac
}

function path_parent() {
  local path="$1"
  dirname -- "$path"
}

function path_base() {
  local path="$1"
  basename -- "$path"
}

function split_name_ext() {
  local base="$1"
  local stem_ref="$2"
  local ext_ref="$3"
  local stem=""
  local ext=""

  if [[ "$base" == .* && "$base" != *.* ]]; then
    stem="$base"
    ext=""
  elif [[ "$base" == *.* ]]; then
    stem="${base%.*}"
    ext=".${base##*.}"
  else
    stem="$base"
    ext=""
  fi

  printf -v "$stem_ref" '%s' "$stem"
  printf -v "$ext_ref" '%s' "$ext"
}

function enumerated_path() {
  local candidate="$1"
  local dir=""
  local base=""
  local stem=""
  local ext=""
  local i=1
  local out=""

  dir="$(path_parent "$candidate")"
  base="$(path_base "$candidate")"
  split_name_ext "$base" stem ext

  out="$candidate"
  while [[ -e "$out" ]]; do
    out="${dir}/${stem}_${i}${ext}"
    ((i++))
  done

  printf '%s' "$out"
}

function resolve_output_path_for_file() {
  local source="$1"
  local desired_base="$2"
  local output_spec="$3"
  local duplicate="$4"
  local dir=""

  dir="$(path_parent "$source")"

  if [[ -n "$output_spec" ]]; then
    if [[ -d "$output_spec" ]]; then
      printf '%s/%s' "$output_spec" "$desired_base"
      return 0
    fi

    if [[ "$output_spec" == */ ]]; then
      printf '%s/%s' "${output_spec%/}" "$desired_base"
      return 0
    fi

    printf '%s' "$output_spec"
    return 0
  fi

  if (( duplicate == 1 )); then
    enumerated_path "${dir}/${desired_base}"
    return 0
  fi

  printf '%s/%s' "$dir" "$desired_base"
}

function resolve_output_path_for_dir() {
  local source="$1"
  local desired_base="$2"
  local output_spec="$3"
  local duplicate="$4"
  local dir=""

  dir="$(path_parent "$source")"

  if [[ -n "$output_spec" ]]; then
    if [[ -d "$output_spec" ]]; then
      printf '%s/%s' "$output_spec" "$desired_base"
      return 0
    fi

    if [[ "$output_spec" == */ ]]; then
      printf '%s/%s' "${output_spec%/}" "$desired_base"
      return 0
    fi

    printf '%s' "$output_spec"
    return 0
  fi

  if (( duplicate == 1 )); then
    enumerated_path "${dir}/${desired_base}"
    return 0
  fi

  printf '%s/%s' "$dir" "$desired_base"
}

function ensure_parent_dir() {
  local path="$1"
  mkdir -p -- "$(path_parent "$path")"
}

function file_content_to_path() {
  local source="$1"
  local destination="$2"
  local spec="$3"
  local tmp=""

  ensure_parent_dir "$destination"
  tmp="$(mktemp "$(path_parent "$destination")/.${PROGRAM_NAME}.XXXXXX")"

  awk -v spec="$spec" '
    function selected(n,    i, part, bounds, start, end, count) {
      if (spec == "") {
        return 1
      }

      count = split(spec, parts, ",")
      for (i = 1; i <= count; i++) {
        part = parts[i]

        if (part ~ /^[0-9]+$/) {
          if (n == part + 0) {
            return 1
          }
          continue
        }

        if (part ~ /^[0-9]+-[0-9]+$/) {
          split(part, bounds, "-")
          start = bounds[1] + 0
          end = bounds[2] + 0
          if (n >= start && n <= end) {
            return 1
          }
        }
      }

      return 0
    }

    {
      if (selected(FNR)) {
        gsub(/ /, "_")
      }
      print
    }
  ' "$source" > "$tmp"

  chmod --reference="$source" "$tmp" 2>/dev/null || true

  if [[ -e "$destination" && "$source" != "$destination" ]]; then
    rm -f -- "$tmp"
    die "destination already exists: $destination"
  fi

  mv -- "$tmp" "$destination"
}

function copy_file_to_path() {
  local source="$1"
  local destination="$2"

  ensure_parent_dir "$destination"
  [[ ! -e "$destination" ]] || die "destination already exists: $destination"
  cp -p -- "$source" "$destination"
}

function process_string_target() {
  local value="$1"
  printf '%s\n' "$(replace_spaces "$value")"
}

function process_directory_target() {
  local source="$1"
  local desired_base=""
  local destination=""

  [[ -d "$source" ]] || die "directory does not exist: $source"

  desired_base="$(replace_spaces "$(path_base "$source")")"
  destination="$(resolve_output_path_for_dir \
    "$source" "$desired_base" "$OUTPUT_PATH" "$DUPLICATE")"

  if [[ "$destination" == "$source" ]]; then
    note "Directory unchanged: $source"
    return 0
  fi

  if (( DUPLICATE == 1 || ${#OUTPUT_PATH} > 0 )); then
    [[ ! -e "$destination" ]] || die "destination already exists: $destination"
    ensure_parent_dir "$destination"
    cp -a -- "$source" "$destination"
    note "Directory copied to: $destination"
    return 0
  fi

  [[ ! -e "$destination" ]] || die "destination already exists: $destination"
  mv -- "$source" "$destination"
  note "Directory renamed to: $destination"
}

function process_file_target() {
  local source="$1"
  local source_base=""
  local desired_base=""
  local destination=""

  [[ -f "$source" ]] || die "file does not exist: $source"

  prompt_file_mode_if_needed "$source"

  source_base="$(path_base "$source")"
  desired_base="$source_base"

  if (( DO_FILE_NAME == 1 )); then
    desired_base="$(replace_spaces "$source_base")"
  fi

  destination="$(resolve_output_path_for_file \
    "$source" "$desired_base" "$OUTPUT_PATH" "$DUPLICATE")"

  if (( DO_FILE_CONTENTS == 1 )); then
    file_content_to_path "$source" "$destination" "$LINE_SPEC"

    if [[ -n "$OUTPUT_PATH" || $DUPLICATE -eq 1 ]]; then
      note "File written to: $destination"
      return 0
    fi

    if [[ "$destination" != "$source" ]]; then
      note "File updated and renamed to: $destination"
    else
      note "File updated in place: $destination"
    fi
    return 0
  fi

  if (( DO_FILE_NAME == 1 )); then
    if [[ -n "$OUTPUT_PATH" || $DUPLICATE -eq 1 ]]; then
      copy_file_to_path "$source" "$destination"
      note "File copied to: $destination"
      return 0
    fi

    if [[ "$destination" == "$source" ]]; then
      note "File name unchanged: $source"
      return 0
    fi

    [[ ! -e "$destination" ]] || die "destination already exists: $destination"
    mv -- "$source" "$destination"
    note "File renamed to: $destination"
    return 0
  fi

  die "internal error: no file operation was selected"
}

function parse_args() {
  while (($# > 0)); do
    case "$1" in
      -s|--string)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        TARGET_STRING="$2"
        shift 2
        ;;
      -f|--file)
        [[ $# -ge 2 ]] || die "$1 requires a path"
        TARGET_FILE="$2"
        shift 2
        ;;
      -d|--dir)
        [[ $# -ge 2 ]] || die "$1 requires a path"
        TARGET_DIR="$2"
        shift 2
        ;;
      -t|--target)
        [[ $# -ge 2 ]] || die "$1 requires a path"
        TARGET_PATH="$2"
        shift 2
        ;;
      --file-contents)
        DO_FILE_CONTENTS=1
        shift
        ;;
      --file-name)
        DO_FILE_NAME=1
        shift
        ;;
      -l|--line-numbers)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        LINE_SPEC="${2//[[:space:]]/}"
        shift 2
        ;;
      -o|--output)
        [[ $# -ge 2 ]] || die "$1 requires a path"
        OUTPUT_PATH="$2"
        shift 2
        ;;
      --duplicate)
        DUPLICATE=1
        shift
        ;;
      -h|--help)
        print_help
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        if [[ -n "$POSITIONAL_INPUT" ]]; then
          die "too many positional arguments"
        fi
        POSITIONAL_INPUT="$1"
        shift
        ;;
    esac
  done

  if (($# > 0)); then
    die "too many positional arguments"
  fi
}

function normalize_targets() {
  local auto=""

  if [[ -n "$LINE_SPEC" ]]; then
    validate_line_spec "$LINE_SPEC"
  fi

  if [[ -n "$LINE_SPEC" && $DO_FILE_CONTENTS -eq 0 ]]; then
    die "--line-numbers requires --file-contents"
  fi

  if [[ -n "$TARGET_PATH" ]]; then
    if [[ -e "$TARGET_PATH" ]]; then
      if [[ -f "$TARGET_PATH" ]]; then
        TARGET_FILE="$TARGET_PATH"
      elif [[ -d "$TARGET_PATH" ]]; then
        TARGET_DIR="$TARGET_PATH"
      else
        die "unsupported target type: $TARGET_PATH"
      fi
    else
      die "target does not exist: $TARGET_PATH"
    fi
  fi

  if [[ -n "$POSITIONAL_INPUT" ]]; then
    auto="$POSITIONAL_INPUT"
    if [[ -e "$auto" ]]; then
      if [[ -f "$auto" ]]; then
        [[ -z "$TARGET_FILE" ]] || die "file target specified more than once"
        TARGET_FILE="$auto"
      elif [[ -d "$auto" ]]; then
        [[ -z "$TARGET_DIR" ]] || die "directory target specified more than once"
        TARGET_DIR="$auto"
      else
        die "unsupported positional target type: $auto"
      fi
    else
      [[ -z "$TARGET_STRING" ]] || die "string target specified more than once"
      TARGET_STRING="$auto"
    fi
  fi

  if [[ -n "$OUTPUT_PATH" && -n "$TARGET_STRING" ]]; then
    die "--output is not supported for string mode; redirect stdout instead"
  fi

  if [[ -n "$TARGET_DIR" && -n "$LINE_SPEC" ]]; then
    die "--line-numbers applies only to file contents"
  fi

  if [[ -n "$TARGET_DIR" && ( $DO_FILE_CONTENTS -eq 1 || $DO_FILE_NAME -eq 1 ) ]]; then
    die "--file-name and --file-contents apply only to files, not directories"
  fi

  if [[ -z "$TARGET_STRING" && -z "$TARGET_FILE" && -z "$TARGET_DIR" ]]; then
    die "no target given"
  fi
}

function main() {
  parse_args "$@"
  normalize_targets

  if [[ -n "$TARGET_STRING" ]]; then
    process_string_target "$TARGET_STRING"
  fi

  if [[ -n "$TARGET_FILE" ]]; then
    process_file_target "$TARGET_FILE"
  fi

  if [[ -n "$TARGET_DIR" ]]; then
    process_directory_target "$TARGET_DIR"
  fi
}

main "$@"
