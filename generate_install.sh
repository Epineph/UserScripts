#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# generate_install_command.sh
#
# Parse yay/paru/pacman transcript files (output_*.txt / output.txt) and generate
# install scripts.
#
# Modes:
#   - latest: generate for the newest output_N.txt without a matching output_N.sh
#   - all:    generate for every output_*.txt (and output.txt) missing a script
#
# Defaults:
#   - Input dir:  current directory
#   - Output dir: same as input dir
#   - Helper:     yay
#   - Paging:     off (help only)
# -----------------------------------------------------------------------------

set -euo pipefail

MODE="latest"        # latest | all
IN_DIR="."
OUT_DIR=""
HELP_PAGING=0
FORCE=0
HELPER="yay"
ASDEPS=1
NEEDED=1
SUDOLOOP=1
BATCHINSTALL=1
INPUT_FILE=""
OUTPUT_FILE=""

function die() {
  printf 'generate_install_command: %s\n' "$*" >&2
  exit 1
}

function have() {
  command -v "$1" >/dev/null 2>&1
}

function pager() {
  if [[ "$HELP_PAGING" -eq 1 ]] && have bat; then
    bat --paging=always --plain
  else
    cat
  fi
}

function show_help() {
  cat <<'EOF' | pager
generate_install_command.sh — create install scripts from log transcripts.

Usage:
  generate_install_command.sh [OPTIONS]

Options:
  -h, --help              Show help and exit
  -m, --mode MODE         latest (default) or all
  -d, --dir DIR           Input directory (default: .)
  -o, --out DIR           Output directory (default: same as --dir)
  -i, --input FILE        Explicit input file (only meaningful in latest mode)
  -O, --output FILE       Explicit output file (only meaningful with --input)
  --helper CMD            yay (default) or paru (or any AUR helper name)
  --no-asdeps             Do not add --asdeps
  --no-needed             Do not add --needed
  --no-sudoloop           Do not add --sudoloop
  --no-batchinstall       Do not add --batchinstall
  --force                 Regenerate even if output script already exists
  --paging                Page help via bat if available, else cat

What it parses (common cases):
  1) Optional-deps style lines:
       "  pkgname: description..."
  2) yay/paru summary lines:
       "AUR Explicit (N): pkg1, pkg2, ..."
       "AUR Dependency (N): pkg1, pkg2, ..."
       "Sync Explicit (N): pkg1, pkg2, ..."
       (and similar)

Examples:
  # Latest unprocessed transcript -> output_N.sh
  generate_install_command.sh

  # Process all transcripts in the directory
  generate_install_command.sh --mode all

  # Use paru and do not mark as deps
  generate_install_command.sh --helper paru --no-asdeps

  # Explicit file -> explicit output
  generate_install_command.sh --input output_103.txt --output out.sh
EOF
}

function is_pkg_token() {
  # Conservative Arch-like package token:
  # - starts with [a-z0-9]
  # - then any of [a-z0-9+_.@-]
  [[ "$1" =~ ^[a-z0-9][a-z0-9+_.@-]*$ ]]
}

function uniq_preserve_order() {
  # Reads tokens on stdin (one per line) and prints unique tokens in first-seen
  # order. Uses bash assoc array.
  local tok
  declare -A seen=()
  while IFS= read -r tok; do
    [[ -z "$tok" ]] && continue
    if [[ -z "${seen[$tok]+x}" ]]; then
      seen["$tok"]=1
      printf '%s\n' "$tok"
    fi
  done
}

function extract_from_optional_deps() {
  local f="$1"
  # Lines like:
  #   "  pkgname: blah"
  # Capture "pkgname"
  awk '
    /^[[:space:]]+[[:graph:]][^[:space:]]*:[[:space:]]/ {
      gsub(/^[[:space:]]+/, "", $0)
      split($0, a, ":")
      print a[1]
    }
  ' "$f"
}

function extract_from_summary_lists() {
  local f="$1"
  # Lines like:
  #   "AUR Explicit (130): pkg1, pkg2, pkg3"
  #   "Sync Dependency (74): pkg1, pkg2"
  #
  # We take everything after the first ":" and split by comma.
  awk '
    /^(AUR|Sync)[[:space:]]+(Explicit|Dependency|Make[[:space:]]+Dependency|Check[[:space:]]+Dependency)[[:space:]]+\([0-9]+\):[[:space:]]/ {
      sub(/^[^:]*:[[:space:]]*/, "", $0)
      n = split($0, a, ",[[:space:]]*")
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[i])
        if (a[i] != "") print a[i]
      }
    }
  ' "$f"
}

function extract_packages() {
  local f="$1"
  local tok

  {
    extract_from_optional_deps "$f"
    extract_from_summary_lists "$f"
  } \
  | awk '{print $0}' \
  | while IFS= read -r tok; do
      # Strip common trailing punctuation.
      tok="${tok%:}"
      tok="${tok%,}"
      tok="${tok%;}"
      tok="${tok%.}"

      # Drop obvious repo-qualified tokens if they sneak in (e.g. extra/pkg).
      # Keep only the tail part after "/".
      if [[ "$tok" == */* ]]; then
        tok="${tok##*/}"
      fi

      if is_pkg_token "$tok"; then
        printf '%s\n' "$tok"
      fi
    done \
  | uniq_preserve_order
}

function latest_unprocessed_file() {
  local dir="$1"
  local f bn num max=0 latest=""

  shopt -s nullglob
  for f in "$dir"/output_*.txt; do
    bn="${f##*/}"
    num="${bn#output_}"
    num="${num%.txt}"
    [[ "$num" =~ ^[0-9]+$ ]] || continue
    if [[ ! -f "${f%.txt}.sh" ]] || [[ "$FORCE" -eq 1 ]]; then
      if (( num > max )); then
        max="$num"
        latest="$f"
      fi
    fi
  done
  shopt -u nullglob

  if [[ -z "$latest" ]] && [[ -f "$dir/output.txt" ]]; then
    if [[ ! -f "$dir/result.sh" ]] || [[ "$FORCE" -eq 1 ]]; then
      latest="$dir/output.txt"
    fi
  fi

  printf '%s\n' "$latest"
}

function all_candidate_files() {
  local dir="$1"
  local f

  shopt -s nullglob
  for f in "$dir"/output_*.txt; do
    if [[ "$FORCE" -eq 1 ]] || [[ ! -f "${f%.txt}.sh" ]]; then
      printf '%s\n' "$f"
    fi
  done
  shopt -u nullglob

  if [[ -f "$dir/output.txt" ]]; then
    if [[ "$FORCE" -eq 1 ]] || [[ ! -f "$dir/result.sh" ]]; then
      printf '%s\n' "$dir/output.txt"
    fi
  fi
}

function build_install_command() {
  local helper="$1"
  shift
  local -a pkgs=("$@")
  local -a args=()

  args+=("$helper")

  if [[ "$NEEDED" -eq 1 ]]; then
    args+=(--needed)
  fi

  args+=(-S)

  # pkgs go after -S
  # flags after packages (yay/paru accept this ordering)
  if [[ "$SUDOLOOP" -eq 1 ]]; then
    args+=(--sudoloop)
  fi
  if [[ "$BATCHINSTALL" -eq 1 ]]; then
    args+=(--batchinstall)
  fi
  if [[ "$ASDEPS" -eq 1 ]]; then
    args+=(--asdeps)
  fi

  # Print a shell snippet that uses an array.
  printf 'pkgs=(\n'
  local p
  for p in "${pkgs[@]}"; do
    printf '  %q\n' "$p"
  done
  printf ')\n\n'
  printf 'exec %q ' "$helper"
  if [[ "$NEEDED" -eq 1 ]]; then
    printf -- '--needed '
  fi
  printf -- '-S '
  printf '"${pkgs[@]}" '
  if [[ "$SUDOLOOP" -eq 1 ]]; then
    printf -- '--sudoloop '
  fi
  if [[ "$BATCHINSTALL" -eq 1 ]]; then
    printf -- '--batchinstall '
  fi
  if [[ "$ASDEPS" -eq 1 ]]; then
    printf -- '--asdeps '
  fi
  printf '\n'
}

function output_path_for_input() {
  local in="$1"
  local outdir="$2"
  local base="${in##*/}"

  if [[ "$base" == "output.txt" ]]; then
    printf '%s/result.sh\n' "$outdir"
  else
    printf '%s/%s\n' "$outdir" "${base%.txt}.sh"
  fi
}

function write_script() {
  local input="$1"
  local output="$2"
  local -a pkgs=()

  mapfile -t pkgs < <(extract_packages "$input")

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n\n'
    printf '# Auto-generated from: %s\n' "$(realpath "$input" 2>/dev/null || \
      printf '%s' "$input")"
    printf '# Generated at: %s\n\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"

    if (( ${#pkgs[@]} == 0 )); then
      printf "printf '%s\n' 'No packages detected in input.'\n"
      exit 0
    fi

    build_install_command "$HELPER" "${pkgs[@]}"
  } >"$output"

  chmod +x "$output"
}

function parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) show_help; exit 0 ;;
      -m|--mode)
        [[ $# -ge 2 ]] || die "--mode requires a value"
        MODE="$2"
        shift 2
        ;;
      -d|--dir)
        [[ $# -ge 2 ]] || die "--dir requires a value"
        IN_DIR="$2"
        shift 2
        ;;
      -o|--out)
        [[ $# -ge 2 ]] || die "--out requires a value"
        OUT_DIR="$2"
        shift 2
        ;;
      -i|--input)
        [[ $# -ge 2 ]] || die "--input requires a value"
        INPUT_FILE="$2"
        shift 2
        ;;
      -O|--output)
        [[ $# -ge 2 ]] || die "--output requires a value"
        OUTPUT_FILE="$2"
        shift 2
        ;;
      --helper)
        [[ $# -ge 2 ]] || die "--helper requires a value"
        HELPER="$2"
        shift 2
        ;;
      --no-asdeps) ASDEPS=0; shift ;;
      --no-needed) NEEDED=0; shift ;;
      --no-sudoloop) SUDOLOOP=0; shift ;;
      --no-batchinstall) BATCHINSTALL=0; shift ;;
      --force) FORCE=1; shift ;;
      --paging) HELP_PAGING=1; shift ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  case "$MODE" in
    latest|all) ;;
    *) die "Invalid --mode: $MODE (expected latest or all)" ;;
  esac

  [[ -d "$IN_DIR" ]] || die "Input directory does not exist: $IN_DIR"

  if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="$IN_DIR"
  fi
  mkdir -p -- "$OUT_DIR"
}

function main() {
  parse_args "$@"

  local -a inputs=()

  if [[ -n "$INPUT_FILE" ]]; then
    [[ -f "$INPUT_FILE" ]] || die "Input file does not exist: $INPUT_FILE"
    inputs=("$INPUT_FILE")
  else
    if [[ "$MODE" == "latest" ]]; then
      local f
      f="$(latest_unprocessed_file "$IN_DIR")"
      [[ -n "$f" ]] || die "No suitable output_*.txt / output.txt found."
      inputs=("$f")
    else
      mapfile -t inputs < <(all_candidate_files "$IN_DIR")
      (( ${#inputs[@]} > 0 )) || die "No suitable output_*.txt / output.txt found."
    fi
  fi

  local in out
  for in in "${inputs[@]}"; do
    if [[ -n "$OUTPUT_FILE" ]]; then
      out="$OUTPUT_FILE"
    else
      out="$(output_path_for_input "$in" "$OUT_DIR")"
    fi

    if [[ -f "$out" ]] && [[ "$FORCE" -eq 0 ]]; then
      continue
    fi

    printf 'Processing %s -> %s\n' "$in" "$out"
    write_script "$in" "$out"
  done
}

main "$@"

