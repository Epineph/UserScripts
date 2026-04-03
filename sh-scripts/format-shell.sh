#!/usr/bin/env bash
#===============================================================================
# format-shell.sh — Recursively format and optionally wrap shell scripts
#
# This script applies consistent indentation and style via shfmt, and—if
# available—a line-wrapping formatter (prettier or beautysh) to shell scripts
# under a given path.
#
# Usage:
#   format-shell.sh [options] <target_path>
#
# Options:
#   -p, --path <target_path>    Path (file or directory) to process (required)
#   -m, --max-width <columns>   Wrap lines to this width (default: no wrapping)
#   -i, --indent <spaces>       Number of spaces for indentation (default: 2)
#   -h, --help                  Show this help message and exit
#
# Behavior:
# 1. Validates required tools (shfmt). Optionally detects prettier or beautysh
#    for code-wrapping.
# 2. Finds files ending in .sh or containing a bash/zsh/sh shebang.
# 3. Runs shfmt for style and indentation.
# 4. If max-width is set and prettier or beautysh is installed, runs the
#    wrapping tool with the specified column limit.
#
# Example:
#   # Format all scripts under ./scripts, indent=2, wrap at 80 cols
#   format-shell.sh -p ./scripts -m 80 -i 2
#===============================================================================

set -euo pipefail

#───[ 1. Usage ]───────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 -p <path> [-m <max-width>] [-i <indent>] [-h]

Options:
  -p, --path        Target file or directory to format
  -m, --max-width   Wrap lines to this width (requires 'prettier' or 'beautysh')
  -i, --indent      Spaces for indentation (default: 2)
  -h, --help        Show this message and exit
EOF
  exit 1
}

#───[ 2. Parse args ]──────────────────────────────────────────────────────────────
path=""
max_width=""
indent=2

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--path)
      path="$2"; shift 2;;
    -m|--max-width)
      max_width="$2"; shift 2;;
    -i|--indent)
      indent="$2"; shift 2;;
    -h|--help)
      usage;;
    *)
      echo "Unknown argument: $1" >&2; usage;;
  esac
done

# Validate path
if [[ -z "$path" ]]; then
  echo "Error: --path is required." >&2; usage
fi
if [[ ! -e "$path" ]]; then
  echo "Error: Path '$path' does not exist." >&2; exit 1
fi

#───[ 3. Check tools ]────────────────────────────────────────────────────────────
# shfmt is mandatory
if ! command -v shfmt &>/dev/null; then
  echo "Error: 'shfmt' is required but not found in PATH." >&2
  echo "Install via: sudo pacman -S shfmt  OR  sudo apt-get install shfmt" >&2
  exit 1
fi

# Detect optional wrapping tool
wrap_tool=""
if [[ -n "$max_width" ]]; then
  if command -v prettier &>/dev/null; then
    wrap_tool="prettier"
  elif command -v beautysh &>/dev/null; then
    wrap_tool="beautysh"
  else
    echo "Warning: --max-width set but neither 'prettier' nor 'beautysh' found.
Skipping wrapping." >&2
  fi
fi

#───[ 4. File discovery ]─────────────────────────────────────────────────────────
# Finds *.sh and files with #!/*sh shebang
discover_files() {
  find "$1" \
    \( -type f -name '*.sh' -o -type f -exec grep -Iq '#!.*sh' {} \; \) \
    -print
}

# Build list
mapfile -t targets < <(discover_files "$path")
if [[ ${#targets[@]} -eq 0 ]]; then
  echo "No shell scripts found under '$path'." >&2
  exit 0
fi

echo "Formatting ${#targets[@]} script(s)..."

#───[ 5. Process each file ]─────────────────────────────────────────────────────
for file in "${targets[@]}"; do
  echo "  → $file"
  # Apply shfmt in-place
  shfmt -w -i "$indent" "$file"

  # If wrapping is desired and tool available
  if [[ -n "$wrap_tool" ]]; then
    case "$wrap_tool" in
      prettier)
        # Prettier: parser bash, explicit print width
        prettier --write --parser bash --print-width "$max_width" "$file"
        ;;
      beautysh)
        # beautysh supports max line length flag -l
        beautysh -l "$max_width" -i "$indent" "$file"
        ;;
    esac
  fi
done

echo "Done. All scripts formatted."

