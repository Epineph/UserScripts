#!/usr/bin/env bash
#===============================================================================
# compress.sh — compress one or more files into tar.gz, zip, or rar archives
#
# Usage:
#   compress.sh \
#     -c|--compress <file1> [file2 ...] \
#     -m|--method <tar.gz|zip|rar> \
#     [-p|--password-protected[=PASSWORD]] \
#     [-o|--out-file <path/to/output>] \
#     [-v|--verbose]
#
# Examples:
#   # basic tar.gz
#   compress.sh -c foo.txt bar.log -m tar.gz
#
#   # password-protected zip, password prompted
#   compress.sh -c secret.doc -m zip -p
#
#   # explicit output name (mismatched extension → .zip.tar.gz)
#   compress.sh -c data.csv -m tar.gz -o archive.zip
#
#   # put into existing dir, auto-naming, verbose
#   compress.sh -c *.png -m zip -v -o /home/user/backups/
#===============================================================================

set -euo pipefail

#───[ 1.  Print usage and exit ]─────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 -c|--compress <file1> [file2 ...] -m|--method <tar.gz|zip|rar> 
         [-p|--password-protected[=PASSWORD]] [-o|--out-file <path>] [-v|--verbose]

Options:
  -c, --compress            One or more files to include in the archive
  -m, --method              Compression method: tar.gz, zip, or rar
  -p, --password-protected  Optional PASSWORD (omit to be prompted securely)
  -o, --out-file            Output path or filename. If omitted, auto-named in $(pwd).
  -v, --verbose             Print detailed execution information
  -h, --help                Show this help message and exit
EOF
  exit 1
}

#───[ 2.  Parse options via GNU getopt ]─────────────────────────────────────────
if ! getopt --test >/dev/null; then
  echo "Error: GNU getopt is required." >&2
  exit 1
fi

OPTIONS=c:m:p::o:vh
LONGOPTS=compress:,method:,password-protected::,out-file:,verbose,help

PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@") || usage
eval set -- "$PARSED"

# Initialize
declare -a files=()
method=""
password=""
outopt=""
verbose=false

# Extract options
while true; do
  case "$1" in
  -c | --compress)
    shift
    while [[ $# -gt 0 && "$1" != "--" && ! "$1" =~ ^- ]]; do
      files+=("$1")
      shift
    done
    ;;
  -m | --method)
    method="$2"
    shift 2
    ;;
  -p | --password-protected)
    if [[ -z "${2-}" ]]; then
      read -rsp "Enter password: " password
      echo
    else
      password="$2"
    fi
    shift 2
    ;;
  -o | --out-file)
    outopt="$2"
    shift 2
    ;;
  -v | --verbose)
    verbose=true
    shift
    ;;
  -h | --help)
    usage
    ;;
  --)
    shift
    break
    ;;
  *)
    echo "Unexpected option: $1" >&2
    usage
    ;;
  esac
done

#───[ 3.  Validate mandatory options ]───────────────────────────────────────────
if [ ${#files[@]} -eq 0 ]; then
  echo "Error: No files specified for compression." >&2
  usage
fi

if [[ -z "$method" ]]; then
  echo "Error: Compression method not specified." >&2
  usage
fi

case "$method" in
tar.gz | zip | rar) ;;
*)
  echo "Error: Invalid method '$method'. Choose tar.gz, zip, or rar." >&2
  usage
  ;;
esac

#───[ 4.  Check required compression tools ]──────────────────────────────────────
check_cmd() {
  local cmd=$1 pkg=$2
  if ! command -v "$cmd" &>/dev/null; then
    echo "Compression tool '$cmd' not found." >&2
    if command -v pacman &>/dev/null; then
      echo " → Install with: sudo pacman -S $pkg" >&2
    elif command -v apt-get &>/dev/null; then
      echo " → Install with: sudo apt-get install $pkg" >&2
    fi
    exit 1
  fi
}

case "$method" in
tar.gz) check_cmd tar tar ;;
zip) check_cmd zip zip ;;
rar) check_cmd rar rar ;;
esac

#───[ 5.  Determine output filename and path ]───────────────────────────────────
ext_method="$method"
if [[ -z "$outopt" ]]; then
  outdir="$(pwd)"
  base="compressed_archive"
  i=0
  while [[ -e "$outdir/${base}${i}.${ext_method}" ]]; do ((i++)); done
  outfile="$outdir/${base}${i}.${ext_method}"
  default_name=true
else
  default_name=false
  if [[ "$outopt" == */ ]] || [[ -d "$outopt" ]]; then
    outdir="$outopt"
    base="compressed_archive"
    i=0
    while [[ -e "$outdir/${base}${i}.${ext_method}" ]]; do ((i++)); done
    outfile="$outdir/${base}${i}.${ext_method}"
  else
    dir=$(dirname "$outopt")
    file=$(basename "$outopt")
    [[ "$dir" == "." ]] && outdir="$(pwd)" || {
      [[ ! -d "$dir" ]] && echo "Error: Directory '$dir' does not exist." >&2 && exit 1
      outdir="$dir"
    }

    if [[ "$method" == "tar.gz" ]]; then
      correct_ext=".tar.gz"
      if [[ "$file" == *"$correct_ext" ]]; then
        base_name="${file%$correct_ext}"
        extGiven="tar.gz"
      else
        base_name="${file%.*}"
        extGiven="${file##*.}"
      fi
    else
      correct_ext=".$method"
      if [[ "$file" == *"$correct_ext" ]]; then
        base_name="${file%$correct_ext}"
        extGiven="$method"
      else
        base_name="${file%.*}"
        extGiven="${file##*.}"
      fi
    fi
    if [[ "$extGiven" != "$method" ]]; then outfile="$outdir/${base_name}.${extGiven}.${method}"; else outfile="$outdir/$file"; fi
  fi
fi

#───[ 6.  Verbose logging ]───────────────────────────────────────────────────────
if $verbose; then
  echo "[Verbose] Compression method: $method"
  echo -n "[Verbose] Password protected: "
  [[ -n "$password" ]] && echo "yes" || echo "no"
  real_out=$(realpath "$outfile")
  if $default_name; then
    echo "[Verbose] Default output: '$(basename "$outfile")' saved at '$(dirname "$real_out")'"
  else
    echo "[Verbose] Output file: '$outfile' → '$real_out'"
  fi
fi

#───[ 7.  Perform the compression ]──────────────────────────────────────────────
echo "Compressing files..."
case "$method" in
tar.gz)
  tar czf "$outfile" "${files[@]}"
  ;;
zip)
  if [[ -n "$password" ]]; then zip -P "$password" "$outfile" "${files[@]}"; else zip "$outfile" "${files[@]}"; fi
  ;;
rar)
  if [[ -n "$password" ]]; then rar a -p"$password" "$outfile" "${files[@]}"; else rar a "$outfile" "${files[@]}"; fi
  ;;
esac

echo "Done. Archive created at: $outfile"
