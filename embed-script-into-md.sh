#!/usr/bin/env bash
#
# embed-script-into-md.sh – Extract a line range from a shell script and insert it
#                          into a Markdown file as a fenced bash code block.
#
# SYNOPSIS
#   embed-script-into-md.sh [OPTIONS]
#
# DESCRIPTION
#   This script takes:
#     1. A shell script (<input-script>)
#     2. A Markdown file (<md-file>) containing a unique placeholder marker
#        (default: <!-- INSERT_SCRIPT_HERE -->)
#     3. A start line (N1) and end line (N2)
#
#   It extracts lines N1..N2 from the shell script, wraps them in a triple‐backtick
#   code fence annotated as "bash", and replaces the marker line in the Markdown file
#   with that fenced block.
#
#   If successful, the Markdown file is modified in place.
#
# OPTIONS
#   -h, --help
#       Show this help and exit.
#
#   -i, --input-script <path>
#       Path to the shell script (e.g. git-list-added.sh).
#
#   -m, --md-file <path>
#       Path to the Markdown file you want to modify (e.g. README.md).
#
#   -s, --start-line <N1>
#       First line number to extract from <input-script>.
#
#   -e, --end-line <N2>
#       Last line number to extract from <input-script>.
#
#   -k, --marker "<marker_string>"
#       The exact placeholder text in the Markdown file to replace.
#       Defaults to "<!-- INSERT_SCRIPT_HERE -->" (must be unique).
#
# REQUIREMENTS
#   • bash (4.x+ recommended)
#   • sed, awk, grep (standard GNU utilities)
#
# EXAMPLES
#   # 1) Using default marker:
#   embed-script-into-md.sh \
#     -i git-list-added.sh \
#     -m README.md \
#     -s 1 \
#     -e 50
#
#   # 2) Custom marker:
#   embed-script-into-md.sh \
#     -i git-list-added.sh \
#     -m docs/usage.md \
#     -s 40 \
#     -e 90 \
#     -k "<!-- MY_CUSTOM_MARKER -->"
#
################################################################################

set -euo pipefail

# Default marker if none provided
MARKER="<!-- INSERT_SCRIPT_HERE -->"
INPUT_SCRIPT=""
MD_FILE=""
START_LINE=""
END_LINE=""

#--------------------------------------------------
# show_help: prints the help text between the line
# markers "################################################################################".
#--------------------------------------------------
show_help() {
  awk 'NR<4 { next } /^################################################################################$/ { exit } { print }' "$0"
}

#--------------------------------------------------
# Parse command‐line arguments
#--------------------------------------------------
while (($#)); do
  case "$1" in
  -h | --help)
    show_help
    exit 0
    ;;
  -i | --input-script)
    shift
    if [[ $# -eq 0 ]]; then
      echo "Error: Missing argument for $1" >&2
      exit 1
    fi
    INPUT_SCRIPT="$1"
    shift
    ;;
  -m | --md-file)
    shift
    if [[ $# -eq 0 ]]; then
      echo "Error: Missing argument for $1" >&2
      exit 1
    fi
    MD_FILE="$1"
    shift
    ;;
  -s | --start-line)
    shift
    if [[ $# -eq 0 ]]; then
      echo "Error: Missing argument for $1" >&2
      exit 1
    fi
    START_LINE="$1"
    shift
    ;;
  -e | --end-line)
    shift
    if [[ $# -eq 0 ]]; then
      echo "Error: Missing argument for $1" >&2
      exit 1
    fi
    END_LINE="$1"
    shift
    ;;
  -k | --marker)
    shift
    if [[ $# -eq 0 ]]; then
      echo "Error: Missing argument for $1" >&2
      exit 1
    fi
    MARKER="$1"
    shift
    ;;
  -*)
    echo "Error: Unknown option: $1" >&2
    exit 1
    ;;
  *)
    echo "Error: Unexpected positional argument: $1" >&2
    exit 1
    ;;
  esac
done

#--------------------------------------------------
# Validate required arguments
#--------------------------------------------------
if [[ -z "$INPUT_SCRIPT" || -z "$MD_FILE" || -z "$START_LINE" || -z "$END_LINE" ]]; then
  echo "Error: -i, -m, -s, and -e are all required." >&2
  echo "Run '$0 --help' for usage." >&2
  exit 1
fi

# Ensure numbers are integers
if ! [[ "$START_LINE" =~ ^[0-9]+$ ]]; then
  echo "Error: start-line must be a positive integer." >&2
  exit 1
fi
if ! [[ "$END_LINE" =~ ^[0-9]+$ ]]; then
  echo "Error: end-line must be a positive integer." >&2
  exit 1
fi
if ((START_LINE > END_LINE)); then
  echo "Error: start-line ($START_LINE) cannot exceed end-line ($END_LINE)." >&2
  exit 1
fi

# Check that files exist
if [[ ! -f "$INPUT_SCRIPT" ]]; then
  echo "Error: Input script '$INPUT_SCRIPT' does not exist or is not a regular file." >&2
  exit 1
fi
if [[ ! -f "$MD_FILE" ]]; then
  echo "Error: Markdown file '$MD_FILE' does not exist or is not a regular file." >&2
  exit 1
fi

#--------------------------------------------------
# Verify the marker exists exactly once in the Markdown file
#--------------------------------------------------
MARKER_COUNT
MARKER_COUNT=$(grep -Fxc "$MARKER" "$MD_FILE" || echo "0")
if [[ "$MARKER_COUNT" -eq 0 ]]; then
  echo "Error: Marker '$MARKER' not found in '$MD_FILE'." >&2
  exit 1
elif [[ "$MARKER_COUNT" -gt 1 ]]; then
  echo "Error: Marker '$MARKER' appears more than once in '$MD_FILE' ($MARKER_COUNT times)." >&2
  exit 1
fi

#--------------------------------------------------
# Extract lines N1..N2 from the input script
#--------------------------------------------------
TMP_SNIPPET="$(mktemp embed_snippet_XXXXXX.txt)"
# sed -n 'START,ENDp' prints only that range
sed -n "${START_LINE},${END_LINE}p" "$INPUT_SCRIPT" >"$TMP_SNIPPET"

#--------------------------------------------------
# Prepare the fenced snippet text
#--------------------------------------------------
{
  echo '```bash'
  cat "$TMP_SNIPPET"
  echo '```'
} >"${TMP_SNIPPET}.fenced"

#--------------------------------------------------
# Replace the marker line in the Markdown file with the fenced snippet
# (We use awk to do an “exact line match”—replace the entire line containing the marker)
#--------------------------------------------------
# Create a backup just in case
cp "$MD_FILE" "${MD_FILE}.bak"

awk -v marker="$MARKER" -v snippet_file="${TMP_SNIPPET}.fenced" '
    BEGIN {
        # Read the fenced snippet into an array
        snip_line = 0
        while ((getline line < snippet_file) > 0) {
            snippet[++snip_line] = line
        }
        close(snippet_file)
    }
    {
        if ($0 == marker) {
            # Print each line of the fenced snippet
            for (i = 1; i <= snip_line; i++) {
                print snippet[i]
            }
        } else {
            # Otherwise, print the original line
            print $0
        }
    }
' "$MD_FILE" >"${MD_FILE}.tmp"

# Overwrite the original Markdown with the new content
mv "${MD_FILE}.tmp" "$MD_FILE"

# Clean up temporary files
rm -f "$TMP_SNIPPET" "${TMP_SNIPPET}.fenced"

echo "Successfully embedded lines $START_LINE–$END_LINE of '$INPUT_SCRIPT' into '$MD_FILE'."
echo "A backup was saved as '${MD_FILE}.bak'."
exit 0
