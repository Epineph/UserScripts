#!/usr/bin/env bash

set -euo pipefail

# Check if an argument is given
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <input_file>" >&2
    exit 1
fi

input="$1"

# Process file
awk '
NR == 1 && /^#!/ { print; next }         # Preserve shebang on first line
/^\s*#/ { next }                         # Skip full-line comments
/^\s*$/ { next }                         # Skip blank lines
{ print }                                # Print everything else
' "$input"

