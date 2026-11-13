#!/usr/bin/env bash
#
# yt-best - Download yt-dlp's best available video and audio streams.
#
# Best streams are muxed without re-encoding. The wrapper ignores yt-dlp
# configuration files so saved format limits cannot silently select a
# lower-quality stream.

set -Eeuo pipefail

readonly PROGRAM="${0##*/}"
readonly VERSION="1.3.0"
readonly FORMAT_SELECTOR='bv*+ba/b'
readonly OUTPUT_TEMPLATE='%(title)s [%(id)s] [%(format_id)s].%(ext)s'

output_dir="$PWD"
container_mode="mkv"
container_mode_explicit=0
browser_cookies="chrome"
cookie_mode="auto"
list_formats=0
simulate=0
verbose=0
error_log=""
declare -a urls=()

# -----------------------------------------------------------------------------
# User interface
# -----------------------------------------------------------------------------

function usage() {
  cat <<'EOF'
Usage:
  yt-best [OPTIONS] URL [URL ...]
  yt-best --list-formats URL

Download the best format containing video, adding the best separate audio
stream when needed. If separate streams are unavailable, use the best combined
stream. No resolution or file-size cap is set. The default merge container is
MKV. Try without cookies first; if YouTube requests sign-in, retry that URL
once with Chrome cookies. Cookies are read afresh, never exported to a file.

Options:
  -P, --path DIR          Download directory (default: current directory)
  -b, --browser SPEC      Use browser cookies immediately instead of auto retry
      --cookies-from-browser SPEC
                          Alias for --browser; accepts a yt-dlp browser spec
      --no-cookies        Never read browser cookies or retry with cookies
      --mp4               Remux the final file to MP4 without re-encoding
      --keep-original     Let yt-dlp choose a compatible container
      --keep-container    Alias for --keep-original
  -F, --list-formats      Show formats yt-dlp can currently access
  -s, --simulate          Check selection without downloading the full video
  -v, --verbose           Show yt-dlp debug details
  -h, --help              Show this help
  -V, --version           Show wrapper version
      --                  Treat all remaining arguments as URLs

MP4 is remuxed without re-encoding. If MP4 cannot contain the selected codecs,
yt-dlp/ffmpeg will fail rather than silently lower or re-encode the quality.
Requires yt-dlp and, for actual downloads, ffmpeg. YouTube also needs a supported
JavaScript runtime (Deno is enabled by yt-dlp by default) and its EJS scripts.
Saved yt-dlp configuration is ignored, so pass cookie options to this wrapper.

On Linux/Hyprland, Chrome uses the Secret Service keyring by default here:
chrome+gnomekeyring. An explicit keyring (e.g. chrome+kwallet6) takes precedence.
Run as your desktop user with the keyring unlocked. Browser specs can include
a profile: 'chrome:Profile 1' or 'chrome+gnomekeyring:Default'.
Choose only one cookie option. With --browser, use that source immediately and
do not retry automatically. With --no-cookies, never access browser cookies.
Automatic retries apply only to YouTube sign-in errors, once per URL.

Always quote URLs: an unquoted '&' starts a background job in Bash/Zsh.
Simulation may probe small media fragments to check format availability.
--list-formats fetches metadata only; neither inspection mode creates the
download directory. A URL's '&t=' timestamp does not trim the downloaded video.

Examples:
  # Best streams in MKV, with Chrome cookies only if YouTube requires them
  yt-best 'https://youtu.be/Y-W-w8yNiKU'

  # Same selection, remuxed to MP4; quote the entire URL
  yt-best --mp4 'https://www.youtube.com/watch?v=Y-W-w8yNiKU&t=1921s'

  # Let yt-dlp pick the container
  yt-best --keep-original 'https://youtu.be/Y-W-w8yNiKU'

  # Use your current Chrome session immediately, or select another profile
  yt-best --browser chrome 'https://youtu.be/Y-W-w8yNiKU'
  yt-best --browser 'chrome:Profile 1' 'https://youtu.be/Y-W-w8yNiKU'

  # Override the Linux keyring explicitly
  yt-best -b chrome+gnomekeyring 'https://youtu.be/Y-W-w8yNiKU'
  yt-best -b 'chrome+kwallet6:Default' 'https://youtu.be/Y-W-w8yNiKU'

  # Disable cookies, including automatic retry
  yt-best --no-cookies 'https://youtu.be/Y-W-w8yNiKU'

  # List formats or test best-stream selection without a full download
  yt-best --list-formats 'https://youtu.be/Y-W-w8yNiKU'
  yt-best --mp4 --simulate 'https://youtu.be/Y-W-w8yNiKU'
  yt-best -v -F --browser chrome 'https://youtu.be/Y-W-w8yNiKU'

  # Choose an output directory; multiple quoted URLs are also accepted
  yt-best -P "$HOME/Videos" 'https://youtu.be/Y-W-w8yNiKU'
  yt-best --mp4 'https://youtu.be/VIDEO_ID_1' 'https://youtu.be/VIDEO_ID_2'
EOF
}

function die() {
  printf '%s: error: %s\n' "$PROGRAM" "$*" >&2
  exit 2
}

function set_browser() {
  [[ $cookie_mode == auto ]] ||
    die "choose one cookie option: --browser or --no-cookies"
  [[ -n $1 && $1 != -* ]] || die "a browser spec is required"
  browser_cookies="$1"
  cookie_mode="browser"
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

function parse_arguments() {
  while (($#)); do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      -V | --version)
        printf '%s %s\n' "$PROGRAM" "$VERSION"
        exit 0
        ;;
      -P | --path)
        (($# >= 2)) || die "$1 requires a directory"
        output_dir="$2"
        shift 2
        ;;
      --path=*)
        output_dir="${1#*=}"
        shift
        ;;
      -b | --browser | --cookies-from-browser)
        (($# >= 2)) || die "$1 requires a browser spec"
        set_browser "$2"
        shift 2
        ;;
      --browser=* | --cookies-from-browser=*)
        set_browser "${1#*=}"
        shift
        ;;
      --no-cookies)
        [[ $cookie_mode == auto ]] ||
          die "choose one cookie option: --browser or --no-cookies"
        cookie_mode="none"
        shift
        ;;
      --mp4)
        [[ $container_mode_explicit == 0 || $container_mode == mp4 ]] ||
          die "choose either --mp4 or --keep-original"
        container_mode="mp4"
        container_mode_explicit=1
        shift
        ;;
      --keep-original | --keep-container)
        [[ $container_mode_explicit == 0 || $container_mode == native ]] ||
          die "choose either --mp4 or --keep-original"
        container_mode="native"
        container_mode_explicit=1
        shift
        ;;
      -F | --list-formats)
        list_formats=1
        shift
        ;;
      -s | --simulate)
        simulate=1
        shift
        ;;
      -v | --verbose)
        verbose=1
        shift
        ;;
      --)
        shift
        urls+=("$@")
        break
        ;;
      -*)
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
# Cookie selection and bounded retry
# -----------------------------------------------------------------------------

function configure_browser() {
  local desktop="${XDG_CURRENT_DESKTOP:-}"
  local session="${DESKTOP_SESSION:-}"

  # yt-dlp treats Hyprland as an unknown desktop and chooses basictext. That
  # cannot decrypt Chrome's v11 cookies stored with Secret Service on this host.
  # Keep explicit keyrings and other browsers exactly as the caller supplied.
  if [[ $OSTYPE == linux* &&
    (":${desktop,,}:" == *:hyprland:* || ${session,,} == hyprland) ]]; then
    case "$browser_cookies" in
      chrome | chrome:*)
        browser_cookies="chrome+gnomekeyring${browser_cookies#chrome}"
        ;;
    esac
  fi
}

function cleanup() {
  [[ -z $error_log ]] || rm -f -- "$error_log"
}

function run_ytdlp() {
  local -a result=()

  # Stream stderr to the terminal and a private temporary log. The pipeline
  # waits for tee before inspecting the log; stdout stays separate on fd 3.
  {
    "$@" 2>&1 1>&3 | tee -- "$error_log" >&2
    result=("${PIPESTATUS[@]}")
  } 3>&1
  ((result[0] == 0)) || return "${result[0]}"
  return "${result[1]}"
}

function youtube_needs_cookies() {
  grep -Eiq \
    'ERROR: \[youtube(:[^]]+)?\].*(sign[ -]?in|log[ -]?in|confirm your age|--cookies)' \
    "$error_log"
}

function cookie_help() {
  if grep -Eiq \
    'cannot decrypt|could not be decrypted|failed to decrypt|keyring|cookie database' \
    "$error_log"; then
    printf '%s: %s\n' "$PROGRAM" \
      'Chrome cookies need the matching unlocked desktop keyring.' >&2
    printf '%s\n' \
      'Run as your desktop user. Try --browser chrome+gnomekeyring or' \
      "--browser 'chrome+kwallet6:Default' if Chrome uses KWallet." >&2
  elif youtube_needs_cookies; then
    printf '%s: %s\n' "$PROGRAM" \
      'YouTube still requests sign-in. Open the video in the selected Chrome' >&2
    printf '%s\n' \
      'profile, complete any browser prompt, then retry. For another profile,' \
      "use --browser 'chrome:Profile 1'." >&2
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

function main() {
  parse_arguments "$@"

  command -v yt-dlp >/dev/null 2>&1 ||
    die "yt-dlp is not installed"

  configure_browser
  local -a cmd=(yt-dlp --ignore-config)
  ((verbose)) && cmd+=(--verbose)

  if ((list_formats)); then
    cmd+=(--list-formats)
  else
    [[ -n $output_dir ]] || die "download directory must not be empty"
    if ((simulate)); then
      cmd+=(--simulate)
    else
      command -v ffmpeg >/dev/null 2>&1 ||
        die "ffmpeg is required to merge the best video and audio streams"
      mkdir -p -- "$output_dir" || die "cannot create download directory"
      [[ -d $output_dir && -w $output_dir ]] ||
        die "download directory is not writable: $output_dir"
    fi

    cmd+=(
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
      mkv) cmd+=(--merge-output-format mkv) ;;
      mp4) cmd+=(--merge-output-format mp4 --remux-video mp4) ;;
      native) ;;
    esac
  fi

  # Explicit choices do not need a retry log or any automatic fallback.
  case "$cookie_mode" in
    browser)
      exec "${cmd[@]}" --cookies-from-browser "$browser_cookies" -- "${urls[@]}"
      ;;
    none)
      exec "${cmd[@]}" --no-cookies --no-cookies-from-browser -- "${urls[@]}"
      ;;
  esac

  error_log=$(mktemp "${TMPDIR:-/tmp}/yt-best.XXXXXXXX") ||
    die "cannot create temporary error log"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  local url status final_status=0
  for url in "${urls[@]}"; do
    if run_ytdlp "${cmd[@]}" -- "$url"; then
      continue
    else
      status=$?
    fi
    ((status < 128)) || return "$status"

    # Restrict browser access to explicit YouTube authentication errors. A
    # network, format, or ffmpeg failure must not cause a cookie retry.
    if youtube_needs_cookies; then
      printf '%s: YouTube requires sign-in; retrying once with %s cookies.\n' \
        "$PROGRAM" "$browser_cookies" >&2
      if run_ytdlp "${cmd[@]}" \
        --cookies-from-browser "$browser_cookies" -- "$url"; then
        continue
      else
        status=$?
      fi
      ((status < 128)) || return "$status"
      cookie_help
    fi
    final_status=$status
  done
  return "$final_status"
}

main "$@"
