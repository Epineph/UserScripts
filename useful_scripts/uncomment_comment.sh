#!/usr/bin/env bash
#===============================================================================
# Script: comment_uncomment.sh
# Description:
#   Comment or uncomment specified lines or ranges in a target file.
#   Supports multiple comment/uncomment operations in one invocation.
#
# Usage:
#   ./comment_uncomment.sh -t <file> [(-c | -u) (-r <N:M> | -l <L1,L2,...>)]...
#
# Options:
#   -t, --target     Path to the target file (required)
#   -c, --comment    Switch to comment subsequent -r/-l specifications
#   -u, --uncomment  Switch to uncomment subsequent -r/-l specifications
#   -r, --range      Specify a range of lines as N:M (e.g., 10:20)
#   -l, --lines      Specify individual lines as comma-separated list (e.g., 3,5,8)
#   -h, --help       Display this help message
#
# Example:
#   # Comment lines 3,6,7 and lines 40-60, then uncomment lines 80-90:
#   ./comment_uncomment.sh -t example.conf -c -l 3,6,7 -r 40:60 -u -r 80:90
#===============================================================================

# Variables to hold parameters
target_file=""
declare -a COMMENT_RANGES COMMENT_LINES UNCOMMENT_RANGES UNCOMMENT_LINES
current_op=""

# Function: Display help message
usage() {
  cat <<EOF
Usage: $0 -t <file> [(-c | -u) (-r <N:M> | -l <L1,L2,...>)]...

Options:
  -t, --target     Path to the target file (required)
  -c, --comment    Switch to comment subsequent -r/-l specifications
  -u, --uncomment  Switch to uncomment subsequent -r/-l specifications
  -r, --range      Specify a range of lines as N:M (e.g., 10:20)
  -l, --lines      Specify individual lines as comma-separated list (e.g., 3,5,8)
  -h, --help       Display this help message

Examples:
  # Comment lines 3,6,7 and lines 40-60, then uncomment lines 80-90:
  $0 -t example.conf -c -l 3,6,7 -r 40:60 -u -r 80:90
  # Simply comment lines 2-30:
  $0 -t example.conf -c -r 2:30
  # Uncomment lines 40-50:
  $0 -t example.conf -u -r 40:50
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)
      target_file="$2"; shift 2;;
    -c|--comment)
      current_op="comment"; shift;;
    -u|--uncomment)
      current_op="uncomment"; shift;;
    -r|--range)
      [[ -z "$current_op" ]] && { echo "Error: -r/--range must follow -c/--comment or -u/--uncomment" >&2; exit 1; }
      if [[ "$current_op" == "comment" ]]; then
        COMMENT_RANGES+=("$2")
      else
        UNCOMMENT_RANGES+=("$2")
      fi
      shift 2;;
    -l|--lines)
      [[ -z "$current_op" ]] && { echo "Error: -l/--lines must follow -c/--comment or -u/--uncomment" >&2; exit 1; }
      IFS=',' read -ra LINES <<< "$2"
      for ln in "${LINES[@]}"; do
        if [[ "$current_op" == "comment" ]]; then
          COMMENT_LINES+=("$ln")
        else
          UNCOMMENT_LINES+=("$ln")
        fi
      done
      shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

# Validate target file
if [[ -z "$target_file" ]]; then
  echo "Error: Target file must be specified with -t or --target" >&2
  usage
  exit 1
fi
if [[ ! -e "$target_file" ]]; then
  echo "Error: File not found: $target_file" >&2
  exit 1
fi

# Backup original
cp -p "$target_file" "${target_file}.bak"

echo "Backup saved to ${target_file}.bak"

# Perform comment operations
for range in "${COMMENT_RANGES[@]}"; do
  sed -i "${range}s/^/#/" "$target_file"
done
for line in "${COMMENT_LINES[@]}"; do
  sed -i "${line}s/^/#/" "$target_file"
done

# Perform uncomment operations
for range in "${UNCOMMENT_RANGES[@]}"; do
  sed -i "${range}s/^#//" "$target_file"
done
for line in "${UNCOMMENT_LINES[@]}"; do
  sed -i "${line}s/^#//" "$target_file"
done

echo "Operations completed on $target_file"

