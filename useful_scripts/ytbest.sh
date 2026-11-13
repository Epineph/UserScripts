#!/usr/bin/env bash
#
# ytbest - Download yt-dlp's best available video and audio streams.
#
# Best streams are muxed without re-encoding. The wrapper ignores yt-dlp
# configuration files so saved format limits cannot silently select a
# lower-quality stream.

set -Eeuo pipefail

readonly PROGRAM="${0##*/}"
readonly VERSION="1.1.0"
readonly FORMAT_SELECTOR='bv*+ba/b'
readonly OUTPUT_TEMPLATE='%(title)s [%(id)s] [%(format_id)s].%(ext)s'

output_dir="$PWD"
container_mode="mkv"
container_mode_explicit=0
list_formats=0
verbose=0
declare -a urls=()

# -----------------------------------------------------------------------------
# User interface
# -----------------------------------------------------------------------------

function usage() {
  cat <<'EOF'
Usage:
  ytbest [OPTIONS] URL [URL ...]
  ytbest --list-formats URL

Download the best format containing video, adding the best separate audio
stream when needed. If separate streams are unavailable, use the best combined
stream. No resolution or file-size cap is set. The default merge container is
MKV.

Options:
  -P, --path DIR          Download directory (default: current directory)
      --mp4               Remux the final file to MP4 without re-encoding
      --keep-original     Let yt-dlp choose a compatible container
  -F, --list-formats      Show formats yt-dlp can currently access
  -v, --verbose           Show yt-dlp debug details
  -h, --help              Show this help
  -V, --version           Show wrapper version
      --                  Treat all remaining arguments as URLs

MP4 is remuxed without re-encoding. If MP4 cannot contain the selected codecs,
yt-dlp/ffmpeg will fail rather than silently lower or re-encode the quality.

Examples:
  ytbest 'https://www.youtube.com/watch?v=VIDEO_ID'
  ytbest --mp4 URL
  ytbest --keep-original URL
  ytbest --list-formats 'https://www.youtube.com/watch?v=VIDEO_ID'
  ytbest -P "$HOME/Videos" URL
EOF
}

function die() {
  printf '%s: error: %s\n' "$PROGRAM" "$*" >&2
  exit 2
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

function parse_arguments() {
  while (($#)); do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -V|--version)
        printf '%s %s\n' "$PROGRAM" "$VERSION"
        exit 0
        ;;
      -P|--path)
        (($# >= 2)) || die "$1 requires a directory"
        output_dir="$2"
        shift 2
        ;;
      --path=*)
        output_dir="${1#*=}"
        shift
        ;;
      --mp4)
        [[ $container_mode_explicit == 0 || $container_mode == mp4 ]] ||
          die "choose either --mp4 or --keep-original"
        container_mode="mp4"
        container_mode_explicit=1
        shift
        ;;
      --keep-original|--keep-container)
        [[ $container_mode_explicit == 0 || $container_mode == native ]] ||
          die "choose either --mp4 or --keep-original"
        container_mode="native"
        container_mode_explicit=1
        shift
        ;;
      -F|--list-formats)
        list_formats=1
        shift
        ;;
      -v|--verbose)
        verbose=1
        shift
        ;;
      --)
        shift
        urls+=("$@")
        break
        ;;
      -* )
        die "unknown option: $1 (see --help)"
        ;;
      *)
        urls+=("$1")
        shift
        ;;
    esac
  done

  ((${#urls[@]} > 0)) || die "at least one URL is required"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

function main() {
  parse_arguments "$@"

  command -v yt-dlp >/dev/null 2>&1 ||
    die "yt-dlp is not installed"

  if ((list_formats)); then
    exec yt-dlp --ignore-config --list-formats -- "${urls[@]}"
  fi

  command -v ffmpeg >/dev/null 2>&1 ||
    die "ffmpeg is required to merge the best separate video and audio streams"
  [[ -n $output_dir ]] || die "download directory must not be empty"
  mkdir -p -- "$output_dir" || die "cannot create download directory"
  [[ -d $output_dir && -w $output_dir ]] ||
    die "download directory is not writable: $output_dir"

  local -a cmd=(
    yt-dlp
    --ignore-config
    --format-sort-reset
    --format "$FORMAT_SELECTOR"
    --check-formats
    --abort-on-unavailable-fragments
    --paths "$output_dir"
    --output "$OUTPUT_TEMPLATE"
    --continue
    --no-overwrites
    --newline
  )

  case "$container_mode" in
    mkv)
      cmd+=(--merge-output-format mkv)
      ;;
    mp4)
      cmd+=(--merge-output-format mp4 --remux-video mp4)
      ;;
    native) ;;
  esac

  ((verbose)) && cmd+=(--verbose)
  cmd+=(-- "${urls[@]}")
  exec "${cmd[@]}"
}

main "$@"
