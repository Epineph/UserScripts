#!/usr/bin/env bash
#
# apply-patch.sh — Apply a unified diff to a script, with safe backups,
#                  flexible argument parsing, and optional verbose preview.
#
# SYNOPSIS
#   # Positional mode:
#   apply-patch.sh <orig-script> <diff-file> [<save-path>]
#
#   # Flag mode:
#   apply-patch.sh \
#     -o|--original   <orig-script> \
#     -d|--diff       <diff-file> \
#     [-s|--save      <out-script>] \
#     [-v|--verbose] \
#     [-h|--help]
#
# DESCRIPTION
#   1. Determines original script, diff file, and optional save location
#      either from flags or (if no flags) from the first two or three
#      positional arguments.
#
#   2. If no save path is supplied, it will
#      • back up the original to ~/.logs/scripts/YYYY-MM-DD/HH-MM-SS/,
#      • overwrite the original in place, and
#      • notify you of the backup location.
#
#   3. If a save path IS supplied:
#      a) If it names an existing directory, we write
#         <that-dir>/<orig-basename>-modified.<ext>.
#      b) Otherwise if its parent directory exists, we use it verbatim.
#      In either case the original script is left untouched (no backup).
#
#   4. Applies the patch:
#      • In “in-place” mode, patch modifies the original.
#      • In “save-as” mode, we copy the original to the target and
#        patch that copy via `patch -o`.
#
#   5. If --verbose is given, shows you:
#      • A syntax-highlighted side-by-side preview of the diff,
#        using `delta` if installed, otherwise `bat --style=…`.
#      • A preview of the new file with the same `bat` styling (or
#        falls back to `cat`).
#
# OPTIONS
#   -o, --original  PATH    Path to the original script to patch.
#   -d, --diff      FILE    Unified diff file to apply.
#   -s, --save      PATH    Optional path or directory for the patched output.
#                            If omitted, original is overwritten (with backup).
#   -v, --verbose           Show colored previews of both diff and result.
#   -h, --help              Show this help and exit.
#
set -euo pipefail
IFS=$'\n\t'

#───────────────────────────────────────────────────────────────────────────────
show_help() {
  sed -n '2,40p' "$0"
}

#───────────────────────────────────────────────────────────────────────────────
# 1) PARSE ARGS
declare original="" difffile="" savepath="" verbose=0
declare -a positional=()

while (( $# )); do
  case "$1" in
    -o|--original) shift; original="$1"; shift;;
    -d|--diff)     shift; difffile="$1"; shift;;
    -s|--save)     shift; savepath="$1"; shift;;
    -v|--verbose)  verbose=1; shift;;
    -h|--help)     show_help; exit 0;;
    -*)            echo "Unknown option: $1" >&2; show_help; exit 1;;
    *) positional+=("$1"); shift;;
  esac
done

# If no flags for orig+diff, take from positional:
if [[ -z "$original" && ${#positional[@]} -ge 2 ]]; then
  original="${positional[0]}"
  difffile="${positional[1]}"
  [[ -z "$savepath" && ${#positional[@]} -ge 3 ]] && savepath="${positional[2]}"
fi

# Validate required
if [[ -z "$original" || -z "$difffile" ]]; then
  echo "Error: original script and diff file must be specified." >&2
  show_help; exit 1
fi

if [[ ! -f "$original" ]]; then
  echo "Error: original script '$original' not found." >&2
  exit 1
fi

if [[ ! -f "$difffile" ]]; then
  echo "Error: diff file '$difffile' not found." >&2
  exit 1
fi

#───────────────────────────────────────────────────────────────────────────────
# 2) DETERMINE OUTPUT LOCATION & BACKUP
orig_name=$(basename "$original")
orig_dir=$(dirname  "$original")
ext="${orig_name##*.}"
base="${orig_name%.*}"

if [[ -n "$savepath" ]]; then
  # If it's an existing directory, put <base>-modified.<ext> inside it
  if [[ -d "$savepath" ]]; then
    outpath="$savepath/${base}-modified.${ext}"
  else
    # Otherwise treat savepath as full filename
    outpath="$savepath"
    mkdir -p "$(dirname "$outpath")"  # fail early if parent doesn't exist
  fi
  backed_up=0
else
  # In-place overwrite → backup original first
  timestamp_dir="$HOME/.logs/scripts/$(date +%F)/$(date +%H-%M-%S)"
  mkdir -p "$timestamp_dir"
  cp --preserve=mode,timestamps "$original" "$timestamp_dir/$orig_name.bak"
  echo "🔒 Backed up original to $timestamp_dir/$orig_name.bak"
  outpath="$original"
  backed_up=1
fi

#───────────────────────────────────────────────────────────────────────────────
# 3) APPLY THE PATCH
if [[ "$outpath" != "$original" ]]; then
  cp --preserve=mode,timestamps "$original" "$outpath"
  patch -p0 "$original" < "$difffile" -o "$outpath"
else
  patch -p0 < "$difffile"     # modifies original
fi

echo "✅ Applied diff '$difffile' → '$outpath'"

#───────────────────────────────────────────────────────────────────────────────
# 4) VERBOSE PREVIEW
if (( verbose )); then
  echo
  if command -v delta &>/dev/null; then
    delta --diff-so-fancy --width=80 --paging=never -s "$difffile"
  else
    # fall back to bat if available
    if command -v bat &>/dev/null; then
      bat --style="grid,snip,header" \
          --color="always" --decorations="always" \
          --wrap="character" --tabs=2 --theme="gruvbox-dark" \
          --paging="never" --italic-text="always" \
          --terminal-width="-1" --squeeze-blank --squeeze-limit=2 \
          --diff "$original" "$outpath"
    else
      cat "$difffile"
    fi
  fi

  echo
  echo "—— New file '$outpath' ——"
  if command -v bat &>/dev/null; then
    bat --style="grid,snip,header" \
        --color="always" --decorations="always" \
        --wrap="character" --tabs=2 --theme="gruvbox-dark" \
        --paging="never" --italic-text="always" \
        --terminal-width="-1" --squeeze-blank --squeeze-limit=2 \
        "$outpath"
  else
    cat "$outpath"
  fi
fi

