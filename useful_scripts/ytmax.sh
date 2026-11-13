#!/usr/bin/env bash
#
# ytmax - Download the highest-quality media exposed to yt-dlp.
#
# This wrapper deliberately ignores yt-dlp configuration files so that an old
# size, resolution, codec, or proxy preference cannot silently weaken the
# requested download. Use --yt-dlp-arg for deliberate per-run additions.

set -Eeuo pipefail

readonly PROGRAM="${0##*/}"
readonly VERSION="1.0.0"
readonly FORMAT_SELECTOR='bv+ba/b'
readonly OUTPUT_TEMPLATE='%(title)s [%(id)s].%(ext)s'

declare -a urls=()
declare -a proxies=()
declare -a proxy_files=()
declare -a extra_args=()

download_path="${YTMAX_PATH:-$PWD}"
output_template="$OUTPUT_TEMPLATE"
cookie_file="${YTMAX_COOKIES:-}"
browser_cookies="${YTMAX_BROWSER:-}"
user_agent="${YTMAX_USER_AGENT:-}"
impersonate="${YTMAX_IMPERSONATE:-}"
proxy_from_env="${YTMAX_PROXY:-}"
proxy_file_from_env="${YTMAX_PROXY_FILE:-}"
request_sleep="${YTMAX_REQUEST_SLEEP:-1}"
download_archive=""
anonymous_first=1
direct_first=0
verbose=0
simulate=0
list_formats=0

# -----------------------------------------------------------------------------
# User interface
# -----------------------------------------------------------------------------

function usage() {
  cat <<'EOF'
Usage:
  ytmax [OPTIONS] URL [URL ...]
  ytmax doctor
  ytmax --help

Download the best video-only stream plus the best audio-only stream and merge
them. If separate streams are unavailable, use the best combined stream. No
resolution, bitrate, duration, or file-size limit is imposed.

Authentication:
  -c, --cookies FILE
      Use a Netscape-format cookie file.
  -b, --cookies-from-browser SPEC
      Read current cookies from a browser. SPEC is accepted exactly as yt-dlp
      defines it, for example: firefox, firefox:PROFILE, chromium+kwallet6, or
      chrome:~/.var/app/com.google.Chrome/.
      --browser SPEC is a shorter alias.
      --auth-only
      Do not try anonymously before using supplied cookies. If both cookie
      sources are given, the file and then the browser are separate fallbacks.

Connection routes:
  -p, --proxy URL
      Use an HTTP, HTTPS, or SOCKS proxy. Repeat to add fallback routes.
  -L, --proxy-file FILE
      Read ordered proxy URLs, one per line. Blank lines and lines beginning
      with # are ignored. The word DIRECT adds a direct route.
      --direct-first
      Try a direct connection before explicitly supplied proxy routes.
  -I, --impersonate TARGET
      Impersonate a supported browser client. Use "auto" to let yt-dlp choose.
      This requires yt-dlp impersonation support, normally python-curl_cffi.
  -A, --user-agent STRING
      Send an exact browser User-Agent string.

Output and reliability:
  -P, --path DIR
      Download directory. Default: current directory or $YTMAX_PATH.
  -o, --output TEMPLATE
      yt-dlp output template. Default: %(title)s [%(id)s].%(ext)s
      --archive FILE
      Record successful downloads and skip them on later runs.
      --request-sleep SECONDS
      Delay between extraction requests. Default: 1 second.
  -n, --simulate
      Resolve metadata and show intended work without downloading.
  -F, --list-formats
      List available formats instead of downloading.
  -v, --verbose
      Enable yt-dlp debug output and wrapper route details.
  -X, --yt-dlp-arg ARG
      Add one advanced yt-dlp argument. Repeat for arguments and their values.

Other:
  -h, --help                 Show this help.
  -V, --version              Show the wrapper version.
      doctor                 Check required and optional dependencies.

Environment defaults:
  YTMAX_PATH, YTMAX_COOKIES, YTMAX_BROWSER, YTMAX_PROXY,
  YTMAX_PROXY_FILE, YTMAX_USER_AGENT, YTMAX_IMPERSONATE,
  YTMAX_REQUEST_SLEEP

Examples:
  ytmax 'https://www.youtube.com/watch?v=VIDEO_ID'

  ytmax --browser firefox \
    'https://www.youtube.com/watch?v=VIDEO_ID'

  ytmax --browser 'firefox:default-release' \
    --user-agent 'Mozilla/5.0 ...' URL

  ytmax --proxy 'socks5://127.0.0.1:1080' URL

  ytmax --direct-first --proxy-file "$HOME/.config/ytmax/proxies" URL

Notes:
  * ffmpeg is required to merge the highest-quality separate streams.
  * When cookies are supplied, anonymous access is tried first. This avoids
    exposing an account unnecessarily and can bypass stale-cookie failures.
  * A proxy is not a cookie repair. Cookies, challenges, and IP addresses can
    be session-bound. Use only trusted proxies and solve any browser challenge
    through the same route used for the download.
  * Proxy credentials passed to yt-dlp can be visible in the local process
    list. This wrapper redacts them only from its own status messages.
  * Download only content you are legally entitled to access and retain.
EOF
}

function die() {
  printf '%s: error: %s\n' "$PROGRAM" "$*" >&2
  exit 2
}

function warn() {
  printf '%s: warning: %s\n' "$PROGRAM" "$*" >&2
}

function info() {
  printf '%s: %s\n' "$PROGRAM" "$*" >&2
}

function require_value() {
  local option="$1"
  local count="$2"

  ((count >= 2)) || die "$option requires a value"
}

function version() {
  printf '%s %s\n' "$PROGRAM" "$VERSION"
}

# -----------------------------------------------------------------------------
# Validation helpers
# -----------------------------------------------------------------------------

function is_nonnegative_number() {
  [[ $1 =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
}

function trim_space() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

function redact_proxy() {
  local proxy="$1"

  if [[ -z $proxy ]]; then
    printf 'direct'
  elif [[ $proxy =~ ^([^:]+://)([^/@]+)@(.+)$ ]]; then
    printf '%s***@%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  else
    printf '%s' "$proxy"
  fi
}

function normalise_proxy() {
  local proxy

  proxy="$(trim_space "$1")"
  if [[ ${proxy,,} == direct ]]; then
    printf ''
    return
  fi

  [[ $proxy =~ ^(https?|socks4a?|socks5h?)://[^[:space:]]+$ ]] ||
    die "invalid proxy URL: $(redact_proxy "$proxy")"

  printf '%s' "$proxy"
}

function warn_if_sensitive_permissions() {
  local path="$1"
  local description="$2"
  local mode

  command -v stat >/dev/null 2>&1 || return 0
  mode="$(stat -Lc '%a' -- "$path" 2>/dev/null)" || return 0
  if ((8#$mode & 077)); then
    warn "$description is accessible by group or other users: $path"
    warn "consider: chmod 600 -- '$path'"
  fi
}

function validate_cookie_file() {
  local first_line

  [[ -f $cookie_file ]] || die "cookie file not found: $cookie_file"
  [[ -r $cookie_file ]] || die "cookie file is not readable: $cookie_file"

  IFS= read -r first_line < "$cookie_file" || true
  first_line="${first_line%$'\r'}"
  case "$first_line" in
    '# HTTP Cookie File'|'# Netscape HTTP Cookie File') ;;
    *)
      die "cookie file is not in Netscape format: $cookie_file"
      ;;
  esac

  if LC_ALL=C grep -q $'\r' -- "$cookie_file"; then
    warn "cookie file contains CRLF line endings; Linux expects LF"
  fi
  warn_if_sensitive_permissions "$cookie_file" "cookie file"
}

function add_proxy_file() {
  local path="$1"
  local line

  [[ -f $path ]] || die "proxy file not found: $path"
  [[ -r $path ]] || die "proxy file is not readable: $path"

  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%$'\r'}"
    line="$(trim_space "$line")"
    [[ -z $line || ${line:0:1} == '#' ]] && continue
    proxies+=("$(normalise_proxy "$line")")
  done < "$path"

  if LC_ALL=C grep -Eq '://[^/@[:space:]]+@' -- "$path"; then
    warn_if_sensitive_permissions "$path" "credential-bearing proxy file"
  fi
}

function build_routes() {
  local -n output_ref="$1"
  local -A seen=()
  local proxy
  local key
  local proxy_configuration=0

  ((${#proxies[@]} > 0 || ${#proxy_files[@]} > 0)) &&
    proxy_configuration=1
  if [[ -n $proxy_from_env ]]; then
    proxies+=("$(normalise_proxy "$proxy_from_env")")
    proxy_configuration=1
  fi
  if [[ -n $proxy_file_from_env ]]; then
    proxy_files+=("$proxy_file_from_env")
    proxy_configuration=1
  fi
  for proxy in "${proxy_files[@]}"; do
    add_proxy_file "$proxy"
  done

  if ((${#proxies[@]} == 0)); then
    ((proxy_configuration)) &&
      die "proxy configuration did not contain any connection routes"
    output_ref+=("")
    return
  fi

  if ((direct_first)); then
    output_ref+=("")
    seen['proxy:']=1
  fi
  for proxy in "${proxies[@]}"; do
    key="proxy:$proxy"
    [[ -n ${seen[$key]+set} ]] && continue
    seen[$key]=1
    output_ref+=("$proxy")
  done
}

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------

function doctor() {
  local failures=0
  local ytdlp_version

  if command -v yt-dlp >/dev/null 2>&1; then
    ytdlp_version="$(yt-dlp --version 2>/dev/null || printf 'unknown')"
    printf 'OK       yt-dlp %s\n' "$ytdlp_version"
  else
    printf 'MISSING  yt-dlp (required)\n'
    failures=1
  fi

  if command -v ffmpeg >/dev/null 2>&1; then
    printf 'OK       ffmpeg\n'
  else
    printf 'MISSING  ffmpeg (required for best separate streams)\n'
    failures=1
  fi

  if command -v deno >/dev/null 2>&1 ||
      command -v node >/dev/null 2>&1 ||
      command -v bun >/dev/null 2>&1 ||
      command -v qjs >/dev/null 2>&1; then
    printf 'OK       JavaScript runtime\n'
  else
    printf 'OPTIONAL JavaScript runtime not found; YouTube may fail\n'
  fi

  if command -v python >/dev/null 2>&1 &&
      python -c 'import curl_cffi' >/dev/null 2>&1; then
    printf 'OK       browser impersonation support\n'
  else
    printf 'OPTIONAL python-curl_cffi not found; --impersonate may fail\n'
  fi

  if ((failures)); then
    printf '\nArch Linux installation:\n'
    printf '  sudo pacman -S --needed yt-dlp ffmpeg python-curl_cffi\n'
  fi

  return "$failures"
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
        version
        exit 0
        ;;
      -c|--cookies)
        require_value "$1" "$#"
        cookie_file="$2"
        shift 2
        ;;
      --cookies=*)
        cookie_file="${1#*=}"
        shift
        ;;
      -b|--browser|--cookies-from-browser)
        require_value "$1" "$#"
        browser_cookies="$2"
        shift 2
        ;;
      --browser=*|--cookies-from-browser=*)
        browser_cookies="${1#*=}"
        shift
        ;;
      --auth-only)
        anonymous_first=0
        shift
        ;;
      -p|--proxy)
        require_value "$1" "$#"
        proxies+=("$(normalise_proxy "$2")")
        shift 2
        ;;
      --proxy=*)
        proxies+=("$(normalise_proxy "${1#*=}")")
        shift
        ;;
      -L|--proxy-file)
        require_value "$1" "$#"
        proxy_files+=("$2")
        shift 2
        ;;
      --proxy-file=*)
        proxy_files+=("${1#*=}")
        shift
        ;;
      --direct-first)
        direct_first=1
        shift
        ;;
      -I|--impersonate)
        require_value "$1" "$#"
        impersonate="$2"
        shift 2
        ;;
      --impersonate=*)
        impersonate="${1#*=}"
        shift
        ;;
      -A|--user-agent)
        require_value "$1" "$#"
        user_agent="$2"
        shift 2
        ;;
      --user-agent=*)
        user_agent="${1#*=}"
        shift
        ;;
      -P|--path)
        require_value "$1" "$#"
        download_path="$2"
        shift 2
        ;;
      --path=*)
        download_path="${1#*=}"
        shift
        ;;
      -o|--output)
        require_value "$1" "$#"
        output_template="$2"
        shift 2
        ;;
      --output=*)
        output_template="${1#*=}"
        shift
        ;;
      --archive)
        require_value "$1" "$#"
        download_archive="$2"
        shift 2
        ;;
      --archive=*)
        download_archive="${1#*=}"
        shift
        ;;
      --request-sleep)
        require_value "$1" "$#"
        request_sleep="$2"
        shift 2
        ;;
      --request-sleep=*)
        request_sleep="${1#*=}"
        shift
        ;;
      -n|--simulate)
        simulate=1
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
      -X|--yt-dlp-arg)
        require_value "$1" "$#"
        extra_args+=("$2")
        shift 2
        ;;
      --yt-dlp-arg=*)
        extra_args+=("${1#*=}")
        shift
        ;;
      --)
        shift
        urls+=("$@")
        break
        ;;
      -* )
        die "unknown option: $1"
        ;;
      *)
        urls+=("$1")
        shift
        ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Download execution
# -----------------------------------------------------------------------------

function add_authentication() {
  local -n command_ref="$1"
  local mode="$2"

  case "$mode" in
    anonymous) ;;
    cookie-file) command_ref+=(--cookies "$cookie_file") ;;
    browser) command_ref+=(--cookies-from-browser "$browser_cookies") ;;
    *) die "internal authentication mode is invalid: $mode" ;;
  esac
}

function add_impersonation() {
  local -n command_ref="$1"

  [[ -n $impersonate ]] || return 0
  if [[ $impersonate == auto ]]; then
    command_ref+=(--impersonate "")
  else
    command_ref+=(--impersonate "$impersonate")
  fi
}

function build_common_command() {
  local -n command_ref="$1"

  command_ref=(
    yt-dlp
    --ignore-config
    --newline
    --format-sort-reset
    --format "$FORMAT_SELECTOR"
    --merge-output-format mkv
    --check-formats
    --continue
    --part
    --no-overwrites
    --abort-on-unavailable-fragments
    --retries 20
    --fragment-retries 20
    --extractor-retries 5
    --retry-sleep 'http:exp=1:30'
    --retry-sleep 'fragment:exp=1:30'
    --retry-sleep 'extractor:exp=2:20'
    --socket-timeout 30
    --sleep-requests "$request_sleep"
    --paths "$download_path"
    --output "$output_template"
  )

  [[ -n $user_agent ]] && command_ref+=(--user-agent "$user_agent")
  [[ -n $download_archive ]] &&
    command_ref+=(--download-archive "$download_archive")
  ((simulate)) && command_ref+=(--simulate)
  ((list_formats)) && command_ref+=(--list-formats)
  ((verbose)) && command_ref+=(--verbose)
  add_impersonation "$1"
  command_ref+=("${extra_args[@]}")
}

function run_downloads() {
  local -a routes=()
  local -a auth_modes=()
  local -a command=()
  local auth_available=0
  local proxied_route=0
  local total
  local current=0
  local route
  local auth_mode
  local route_label

  command -v yt-dlp >/dev/null 2>&1 ||
    die "yt-dlp is not installed; run '$PROGRAM doctor'"
  command -v ffmpeg >/dev/null 2>&1 ||
    die "ffmpeg is required for highest-quality stream merging"

  [[ -n $cookie_file || -n $browser_cookies ]] && auth_available=1
  [[ -n $cookie_file ]] && validate_cookie_file
  [[ -n $download_path ]] || die "--path must not be empty"
  [[ -n $output_template ]] || die "--output must not be empty"
  is_nonnegative_number "$request_sleep" ||
    die "--request-sleep must be a non-negative number"

  [[ ! -e $download_path || -d $download_path ]] ||
    die "download path exists but is not a directory: $download_path"
  mkdir -p -- "$download_path" ||
    die "could not create download directory: $download_path"
  [[ -d $download_path && -w $download_path ]] ||
    die "download directory is not writable: $download_path"

  build_routes routes
  ((${#routes[@]} > 0)) || die "no connection routes were configured"

  ((anonymous_first || !auth_available)) && auth_modes+=(anonymous)
  [[ -n $cookie_file ]] && auth_modes+=(cookie-file)
  [[ -n $browser_cookies ]] && auth_modes+=(browser)
  ((${#auth_modes[@]} > 0)) ||
    die "--auth-only requires --cookies or --cookies-from-browser"

  for route in "${routes[@]}"; do
    [[ -n $route ]] && proxied_route=1
  done
  if ((auth_available && proxied_route)); then
    warn "cookies used through another IP may be rejected as session-bound"
  fi

  total=$((${#routes[@]} * ${#auth_modes[@]}))
  for route in "${routes[@]}"; do
    route_label="$(redact_proxy "$route")"
    for auth_mode in "${auth_modes[@]}"; do
      ((current += 1))
      info "attempt $current/$total: $route_label; $auth_mode"

      build_common_command command
      command+=(--proxy "$route")
      add_authentication command "$auth_mode"
      command+=(-- "${urls[@]}")

      if "${command[@]}"; then
        info "completed successfully"
        return 0
      fi

      warn "attempt $current/$total failed"
    done
  done

  warn "all connection and authentication attempts failed"
  warn "run again with --verbose and inspect yt-dlp's final error"
  return 1
}

function main() {
  if (($# == 1)) && [[ $1 == doctor ]]; then
    doctor
    return
  fi

  parse_arguments "$@"
  ((${#urls[@]} > 0)) || die "at least one URL is required"

  run_downloads
}

main "$@"
