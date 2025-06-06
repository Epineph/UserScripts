#!/usr/bin/env bash
#
# batwrap-to-pdf.sh – Convert the ANSI‐coloured output of batwrap into a PDF
#
# SYNOPSIS
#   batwrap-to-pdf.sh [OPTIONS] <input_script> <output_pdf>
#
# DESCRIPTION
#   This script runs `batwrap` on <input_script>, captures its ANSI‐coloured output,
#   converts that to HTML via `aha`, then converts the HTML to PDF via `wkhtmltopdf`.
#
#   The resulting PDF will preserve:
#     • syntax highlighting
#     • header/grid styling (if you used --style="header,grid,…")
#     • any ANSI‐colour escapes used by batwrap
#
#   If you don’t need custom batwrap arguments, omit --batargs. By default, it will
#   simply call `batwrap -t <input_script>`.
#
# OPTIONS
#   -h, --help
#       Show this help and exit.
#
#   --batargs="<string>"
#       Quoted string of extra arguments to pass to batwrap. For example:
#         --batargs="--style='header,grid' --color=always --tabs=2"
#
# REQUIREMENTS
#   • batwrap  (any version that produces ANSI output)
#   • aha      (ANSI → HTML converter)
#   • wkhtmltopdf  (HTML → PDF converter)
#
# EXAMPLES
#   # 1) Basic usage (no extra batwrap options):
#   ./batwrap-to-pdf.sh git-list-added.sh added-files.pdf
#
#   # 2) With extra batwrap styling options:
#   ./batwrap-to-pdf.sh --batargs="--style='header,grid' --color='always' --tabs='2'" \
#       git-list-added.sh git-list-added.pdf
#
################################################################################

set -euo pipefail

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
BATARGS=""
INPUT_SCRIPT=""
OUTPUT_PDF=""

while (( $# )); do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        --batargs=*)
            # Extract string after '='
            BATARGS="${1#--batargs=}"
            shift
            ;;
        --batargs)
            # If user does: --batargs "<args>"
            shift
            if [[ $# -eq 0 ]]; then
                echo "Error: --batargs requires an argument" >&2
                exit 1
            fi
            BATARGS="$1"
            shift
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            # Assume the first non‐option is the input script, second is output PDF
            if [[ -z "$INPUT_SCRIPT" ]]; then
                INPUT_SCRIPT="$1"
            elif [[ -z "$OUTPUT_PDF" ]]; then
                OUTPUT_PDF="$1"
            else
                echo "Error: too many positional arguments" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

#--------------------------------------------------
# Validate required positional arguments
#--------------------------------------------------
if [[ -z "$INPUT_SCRIPT" || -z "$OUTPUT_PDF" ]]; then
    echo "Error: <input_script> and <output_pdf> are both required." >&2
    echo "Run '$0 --help' for usage." >&2
    exit 1
fi

if [[ ! -f "$INPUT_SCRIPT" ]]; then
    echo "Error: Input script '$INPUT_SCRIPT' not found or not a regular file." >&2
    exit 1
fi

#--------------------------------------------------
# Check for required external commands
#--------------------------------------------------
if ! command -v batwrap &>/dev/null; then
    echo "Error: 'batwrap' is not installed. Please install it (e.g. via pacman)." >&2
    exit 1
fi
if ! command -v aha &>/dev/null; then
    echo "Error: 'aha' is not installed. Install via 'sudo pacman -S aha'." >&2
    exit 1
fi
if ! command -v wkhtmltopdf &>/dev/null; then
    echo "Error: 'wkhtmltopdf' is not installed. Install via 'sudo pacman -S wkhtmltopdf'." >&2
    exit 1
fi

#--------------------------------------------------
# Build intermediate HTML filename
# (randomized or based on output name)
#--------------------------------------------------
HTML_TMP="$(mktemp --suffix=.html batwrap_XXXXXX.html)"

#--------------------------------------------------
# Run batwrap → aha → HTML_TMP
#--------------------------------------------------
echo "Running batwrap on '$INPUT_SCRIPT'..."
if [[ -n "$BATARGS" ]]; then
    # shellcheck disable=SC2086
    batwrap -t "$INPUT_SCRIPT" $BATARGS | aha --black > "$HTML_TMP"
else
    batwrap -t "$INPUT_SCRIPT" | aha --black > "$HTML_TMP"
fi

#--------------------------------------------------
# Convert HTML to PDF
#--------------------------------------------------
echo "Converting HTML to PDF: '$OUTPUT_PDF'..."
wkhtmltopdf "$HTML_TMP" "$OUTPUT_PDF"

#--------------------------------------------------
# Clean up intermediate file
#--------------------------------------------------
rm -f "$HTML_TMP"

echo "Done. PDF saved to '$OUTPUT_PDF'."
exit 0

