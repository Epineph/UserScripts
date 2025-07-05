#!/usr/bin/env bash
#
# batwrap-pdf-v4.sh – Convert ANSI-coloured output (from file or stdin) to a white-background PDF
#
# SYNOPSIS
#   batwrap-pdf-v4.sh [OPTIONS] <input_script> <output_pdf>
#   cat some_output.txt | batwrap-pdf-v4.sh <output_pdf>
#   help foo | batwrap-pdf-v4.sh <output_pdf>
#
# DESCRIPTION
#   Runs `batwrap` on <input_script> (or on piped stdin), converts ANSI
#   output to HTML via `aha` (white background), strips background-color
#   styles so highlights appear on white, then renders to PDF via `wkhtmltopdf`.
#
# OPTIONS
#   -h, --help
#       Show this help and exit.
#   --batargs "<args>"
#       Quoted string of extra arguments to pass to batwrap,
#       e.g. "--style=header,grid --tabs=2 --highlight-line=:1".
#
set -euo pipefail
IFS=$'\n\t'

show_help() {
    sed -n '2,20p' "$0"
}

BATARGS=""
declare -a positional=()

#--------------------------------------------------
# Parse command-line arguments
#--------------------------------------------------
while (( $# )); do
    case "$1" in
        -h|--help)
            show_help; exit 0;;
        --batargs)
            shift
            if [[ $# -eq 0 ]]; then
                echo "Error: --batargs requires an argument" >&2
                exit 1
            fi
            BATARGS="$1"
            shift;;
        --batargs=*)
            BATARGS="${1#--batargs=}"
            shift;;
        -* )
            echo "Unknown option: $1" >&2; exit 1;;
        *)
            positional+=("$1")
            shift;;
    esac
done

#--------------------------------------------------
# Determine input and output
#--------------------------------------------------
INPUT_SCRIPT=""
OUTPUT_PDF=""
TEMP_IN=""

if (( ${#positional[@]} == 2 )); then
    INPUT_SCRIPT="${positional[0]}"
    OUTPUT_PDF="${positional[1]}"
elif (( ${#positional[@]} == 1 )); then
    OUTPUT_PDF="${positional[0]}"
    # If stdin is piped, read it
    if ! [ -t 0 ]; then
        TEMP_IN="$(mktemp --suffix=".ansi")"
        cat - > "$TEMP_IN"
        INPUT_SCRIPT="$TEMP_IN"
    else
        echo "Error: No input file provided and stdin is empty." >&2
        show_help; exit 1
    fi
else
    echo "Error: Expected either 2 arguments (input and output) or 1 argument (output when piping)." >&2
    show_help; exit 1
fi

# Validate paths
if [[ ! -f "$INPUT_SCRIPT" ]]; then
    echo "Error: Input '$INPUT_SCRIPT' not found." >&2
    exit 1
fi

# Ensure required commands
for cmd in batwrap aha wkhtmltopdf; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' not found; install it." >&2; exit 1
    fi
done

#--------------------------------------------------
# Prepare temporary HTML
#--------------------------------------------------
HTML_TMP="$(mktemp --suffix=".html" batwrap_XXXXXX)"

echo "Running batwrap on '$INPUT_SCRIPT'..."
if [[ -n "$BATARGS" ]]; then
    IFS=' ' read -r -a _bat_args <<< "$BATARGS"
    batwrap -t "$INPUT_SCRIPT" "${_bat_args[@]}" | aha --black > "$HTML_TMP"
else
    batwrap -t "$INPUT_SCRIPT" | aha --black > "$HTML_TMP"
fi

# Strip background-color styles
sed -E -i 's/background-color:[^;]+;/background-color: transparent;/g' "$HTML_TMP"

#--------------------------------------------------
# Convert HTML to PDF
#--------------------------------------------------
echo "Converting HTML to PDF: '$OUTPUT_PDF'..."
wkhtmltopdf --background "$HTML_TMP" "$OUTPUT_PDF"

# Cleanup
rm -f "$HTML_TMP"
if [[ -n "$TEMP_IN" ]]; then
    rm -f "$TEMP_IN"
fi

echo "PDF generated at '$OUTPUT_PDF'"
exit 0

