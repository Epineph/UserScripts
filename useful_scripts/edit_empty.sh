#!/usr/bin/env bash
set -euo pipefail

#============================================================
# Script Name   : edit_empty.sh
# Description   : Backup one or more scripts, empty them, and open in an editor.
# Author        : Epineph (with ChatGPT)
#============================================================

show_help() {
  cat << EOF
Usage: ${0##*/} [OPTIONS] SCRIPT_PATH [SCRIPT_PATH...]

Back up each SCRIPT_PATH to:
  \$HOME/.logs/scripts/<YYYY-MM-DD>/<HH-MM-SS>/<script>.bak
then empty the original and open all provided paths in an editor.

Options:
  -e, --editor EDITOR     Specify which editor to use (default: \$EDITOR or 'nano').
  -v, -V, --verbose       Print extra information about backups and directories.
  -h, --help              Show this help message and exit.

Examples:
  ${0##*/} my_script.sh
  ${0##*/} -e vim -v script1.sh script2.py
EOF
}

#=============================#
#       PARSE ARGUMENTS       #
#=============================#
editor=""
verbose=0
declare -a script_paths=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--editor)
      shift; editor="$1"; shift;;
    -v| -V|--verbose)
      verbose=1; shift;;
    -h|--help)
      show_help; exit 0;;
    -* )
      echo "Unknown option: $1" >&2; show_help; exit 1;;
    *)
      script_paths+=("$1"); shift;;
  esac
done

if [[ ${#script_paths[@]} -eq 0 ]]; then
  echo "Error: No script paths provided." >&2
  show_help; exit 1
fi

#=============================#
#         VARIABLES          #
#=============================#
# Determine editor: CLI > \$EDITOR > nano
chosen_editor="${editor:-${EDITOR:-nano}}"

# Check editor exists
if ! command -v "$chosen_editor" &>/dev/null; then
  echo "Editor '$chosen_editor' not found in PATH." >&2
  exit 1
fi

# Timestamped backup dir
date_str=$(date +%F)
time_str=$(date +%H-%M-%S)
backup_dir="$HOME/.logs/scripts/$date_str/$time_str"

[[ $verbose -eq 1 ]] && echo "Backup directory: $backup_dir"

mkdir -p "$backup_dir"

#=============================#
#       PROCESS SCRIPTS      #
#=============================#
for script_path in "${script_paths[@]}"; do
  if [[ ! -f "$script_path" ]]; then
    echo "Warning: '$script_path' does not exist or is not a file. Skipping." >&2
    continue
  fi

  script_name=$(basename "$script_path")
  backup_path="$backup_dir/$script_name.bak"

  [[ $verbose -eq 1 ]] && echo "Backing up '$script_path' → '$backup_path'"
  cp --preserve=mode,timestamps "$script_path" "$backup_path"

  [[ $verbose -eq 1 ]] && echo "Emptying original '$script_path'"
  : > "$script_path"
done

#=============================#
#      OPEN IN EDITOR        #
#=============================#
if [[ $verbose -eq 1 ]]; then
  echo "Opening scripts in '$chosen_editor': ${script_paths[*]}"
fi
"$chosen_editor" "${script_paths[@]}"

