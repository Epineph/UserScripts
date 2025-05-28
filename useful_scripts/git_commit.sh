#!/usr/bin/env bash

# === HELP SECTION ===
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat <<EOF
Usage: git_commit.sh [--verbose|-v]

If no argument is given, commits with the message:
  "Changes made at <date>"

If --verbose or -v is given, includes the time:
  "Changes made at <date> <time>"
EOF
    exit 0
fi

# === DATE AND TIME ===
date_str="$(date +'%d-%m-%Y')"

# If verbose flag is passed, add time
if [[ "$1" == "-v" || "$1" == "--verbose" ]]; then
    time_str="$(date +'%H:%M:%S')"
    msg="Changes made at ${date_str} ${time_str}"
else
    msg="Changes made at ${date_str}"
fi

# === COMMIT ===
git commit -m "$msg"

