#!/usr/bin/env bash
set -euo pipefail

# make-demo-script.sh
# -----------------------------------------------------------------------------
# Example: generate a new shell script using a here-doc (cat <<'EOF' > file).
# The generated script contains its own --help section implemented via a here-doc.
# -----------------------------------------------------------------------------

function main() {
  local out="${1:-./demo-tool}"
  create_demo_script "$out"
  chmod 755 "$out"
  printf 'Wrote %s\n' "$out"
}

function create_demo_script() {
  local out="$1"

  # Use <<'EOF' (quoted) so $variables inside the generated script are not
  # expanded now; they remain literal for the generated script to interpret.
  cat <<'EOF' > "$out"
#!/usr/bin/env bash
set -euo pipefail

# demo-tool
# -----------------------------------------------------------------------------
# Demo CLI tool generated via a here-doc.
# -----------------------------------------------------------------------------

function usage() {
  cat <<'HELP'
demo-tool

Usage:
  demo-tool [--name NAME] [--times N]
  demo-tool --help

Options:
  --name NAME     Name to greet (default: world)
  --times N       Number of greetings (default: 1)
  -h, --help      Show this help

Examples:
  demo-tool
  demo-tool --name Heini
  demo-tool --name Heini --times 3
HELP
}

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function main() {
  local name="world"
  local times="1"

  while (($#)); do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --name)
        shift || die "--name requires a value"
        name="$1"
        ;;
      --times)
        shift || die "--times requires a value"
        times="$1"
        ;;
      --)
        shift
        break
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
    shift
  done

  # Basic validation
  [[ "$times" =~ ^[0-9]+$ ]] || die "--times must be a non-negative integer"

  local i
  for ((i=1; i<=times; i++)); do
    printf 'Hello, %s! (%d/%d)\n' "$name" "$i" "$times"
  done
}

main "$@"
EOF
}

main "$@"
