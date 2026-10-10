#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Set or temporarily override MAKEFLAGS in the per-user makepkg.conf.
#
# Temporary modes use a systemd user unit when available. If that manager is
# unavailable, an active atd installation can provide a timed fallback.
# -----------------------------------------------------------------------------

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C
export LC_ALL
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly OPEN_MARKER='# >>> makepkg-flags-manager (managed block) >>>'
readonly CLOSE_MARKER='# <<< makepkg-flags-manager (managed block) <<<'
readonly DEFAULT_FALLBACK_SECONDS=28800
readonly MAX_TIMER_SECONDS=315360000
readonly UNIT_BASE='makepkg-flags-manager'

VERBOSE=0

function die() {
  local message
  printf -v message '%s ' "$@"
  message=${message% }
  printf '%s: error: %s\n' "$SCRIPT_NAME" "$message" >&2
  exit 1
}

function log() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*"
}

function vlog() {
  if (( VERBOSE )); then
    log "$*"
  fi
}

function usage() {
  cat <<'HELP'
Usage:
  makepkg-flags.sh (-c N | -p low|medium|high) [--persist | --timer ...]
  makepkg-flags.sh --persist [(-c N | -p low|medium|high)]
  makepkg-flags.sh --timer DURATION [(-c N | -p low|medium|high)]
  makepkg-flags.sh --status
  makepkg-flags.sh --revert | --default

Options (option names are case-insensitive):
  -c, --cores N         Set MAKEFLAGS to -jN, where N is a positive integer.
  -p, --preset NAME     Choose low, medium, or high from available processors:
                          low    = max(1, floor(nproc / 4))
                          medium = max(1, floor(nproc / 2))
                          high   = nproc
  --persist             Keep the selected setting until it is changed or
                        reverted. May promote the currently managed setting.
  -t, --timer DURATION  Revert at a deadline. Examples:
                          --timer 90m
                          --timer 1h 30m 15s
                          --timer hours 1 minutes 30 seconds 15
                        A plain integer is interpreted as seconds.
  --revert, --default   Remove this script's override and restore the previous
                        per-user makepkg.conf contents. If this script created
                        the file and nothing else was added, delete the file.
  --status              Show the managed setting and remaining time, if any.
  -v, --verbose         Show additional setup details.
  -h, --help            Show this help.
      --long-help       Show the help and implementation notes.

If neither --persist nor --timer is supplied, the setting is temporary until
reboot: a systemd user service removes it on the next user-manager start. When
systemd --user is unavailable, an active atd service is used for an eight-hour
fallback. If neither scheduler is available, the script makes no change.

The override is written to:
  ${XDG_CONFIG_HOME:-$HOME/.config}/pacman/makepkg.conf

Examples:
  makepkg-flags.sh --preset low
  makepkg-flags.sh --cores 12 --timer hours 2 minutes 30
  makepkg-flags.sh --preset high --persist
  makepkg-flags.sh --status
  makepkg-flags.sh --revert
HELP
}

function long_help() {
  usage
  cat <<'HELP'

Behavior and limits:
  * Low and medium presets use integer division, rounded down and clamped to
    one job. For example, on 6 available processors, low=1, medium=3, high=6.
  * The script edits only its marked block. Existing user configuration outside
    that block is retained. Reverting removes the block so earlier settings
    become effective again.
  * makepkg.conf is shell code. This script writes only a quoted MAKEFLAGS
    assignment containing a validated positive integer.
  * Temporary systemd deadlines use an absolute UTC calendar time and
    Persistent=true. If the user manager was stopped or the machine was off at
    the deadline, cleanup runs when that manager next starts. Without lingering,
    this is normally at the next login.
  * The atd fallback also runs after its deadline when atd processes its queue.
    It uses eight hours only for the default temporary mode when systemd --user
    cannot be reached. Explicit --timer durations are preserved.
  * --revert removes this manager's override and its temporary scheduling state.
    It does not edit /etc/makepkg.conf or ~/.makepkg.conf.
  * A command-scoped one-command override is intentionally separate: makepkg
    configuration is sourced by makepkg, while an environment-only wrapper
    needs different process and shell error-handling semantics.
HELP
}

function xdg_config_home() {
  local value="${XDG_CONFIG_HOME:-${HOME:-}/.config}"
  [[ -n "$value" ]] || die 'HOME is not set and XDG_CONFIG_HOME is empty.'
  [[ "$value" == /* ]] || die 'XDG_CONFIG_HOME must be an absolute path.'
  [[ "$value" != *$'\n'* ]] || die 'XDG_CONFIG_HOME may not contain a newline.'
  printf '%s\n' "${value%/}"
}

function path_quote_bash() {
  printf '%q' "$1"
}

function systemd_quote() {
  local value="$1"
  value=${value//%/%%}
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

function is_unit_word() {
  case "$1" in
    h|hr|hrs|hour|hours) return 0 ;;
    m|min|mins|minute|minutes) return 0 ;;
    s|sec|secs|second|seconds) return 0 ;;
    *) return 1 ;;
  esac
}

function unit_multiplier() {
  case "$1" in
    h|hr|hrs|hour|hours) printf '3600\n' ;;
    m|min|mins|minute|minutes) printf '60\n' ;;
    s|sec|secs|second|seconds) printf '1\n' ;;
    *) return 1 ;;
  esac
}

function add_timer_component() {
  local amount="$1"
  local multiplier="$2"
  local product

  [[ "$amount" =~ ^[0-9]{1,9}$ ]] || die "Invalid timer amount: $amount"
  amount=$((10#$amount))
  product=$((amount * multiplier))
  (( product <= MAX_TIMER_SECONDS - TIMER_SECONDS )) || \
    die 'Timer exceeds the supported maximum of ten years.'
  TIMER_SECONDS=$((TIMER_SECONDS + product))
}

function parse_compact_duration() {
  local input="$1"
  local rest="$input"
  local amount suffix multiplier

  if [[ "$input" =~ ^[0-9]+$ ]]; then
    add_timer_component "$input" 1
    return
  fi

  while [[ -n "$rest" ]]; do
    if [[ "$rest" =~ ^([0-9]+)(h|m|s)(.*)$ ]]; then
      amount="${BASH_REMATCH[1]}"
      suffix="${BASH_REMATCH[2]}"
      rest="${BASH_REMATCH[3]}"
      multiplier=$(unit_multiplier "$suffix")
      add_timer_component "$amount" "$multiplier"
    else
      die "Invalid duration '$input'; use forms such as 90m or 1h30m."
    fi
  done
}

function is_option_word() {
  case "$1" in
    -h|--help|--long-help|-v|--verbose|--persist|--status|--revert|--default|\
    -c|--cores|-p|--preset|-t|--timer|--cores=*|--preset=*|--timer=*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

function parse_timer_args() {
  local token lower next unit multiplier
  local consumed=0
  TIMER_SECONDS=0

  while (($#)); do
    token="$1"
    lower="${token,,}"
    if is_option_word "$lower"; then
      break
    fi

    if is_unit_word "$lower"; then
      (($# >= 2)) || die "Timer unit '$token' needs an integer amount."
      [[ "$2" =~ ^[0-9]+$ ]] || \
        die "Timer unit '$token' needs an integer amount."
      multiplier=$(unit_multiplier "$lower")
      add_timer_component "$2" "$multiplier"
      shift 2
      consumed=$((consumed + 2))
      continue
    fi

    if [[ "$lower" =~ ^[0-9]+$ ]] && (($# >= 2)); then
      next="${2,,}"
      if is_unit_word "$next"; then
        multiplier=$(unit_multiplier "$next")
        add_timer_component "$lower" "$multiplier"
        shift 2
        consumed=$((consumed + 2))
        continue
      fi
    fi

    parse_compact_duration "$lower"
    shift
    consumed=$((consumed + 1))
  done

  (( consumed > 0 )) || die '--timer requires at least one duration.'
  (( TIMER_SECONDS > 0 )) || die 'Timer duration must be greater than zero.'
  TIMER_CONSUMED=$consumed
}

function normalize_positive_integer() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]{1,9}$ ]] || die "$label must be a positive integer."
  value=$((10#$value))
  (( value > 0 )) || die "$label must be at least 1."
  printf '%s\n' "$value"
}

function detect_systemd_user() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl --user show-environment >/dev/null 2>&1
}

function detect_at_scheduler() {
  command -v at >/dev/null 2>&1 || return 1
  command -v atq >/dev/null 2>&1 || return 1
  command -v atrm >/dev/null 2>&1 || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl is-active --quiet atd.service >/dev/null 2>&1
}

function read_state_value() {
  local wanted="$1"
  local line key value
  [[ -f "$STATE_FILE" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    if [[ "$key" == "$wanted" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  done < "$STATE_FILE"
  return 1
}

function write_state() {
  local mode="$1"
  local jobs="$2"
  local created="$3"
  local scheduler="$4"
  local expiry="$5"
  local duration="$6"
  local boot_id="$7"
  local at_id="$8"
  local tmp

  mkdir -p -- "$STATE_DIR"
  chmod 700 -- "$STATE_DIR"
  tmp=$(mktemp "$STATE_DIR/state.XXXXXX")
  {
    printf 'mode=%s\n' "$mode"
    printf 'jobs=%s\n' "$jobs"
    printf 'created_config=%s\n' "$created"
    printf 'scheduler=%s\n' "$scheduler"
    printf 'expires_at=%s\n' "$expiry"
    printf 'duration_seconds=%s\n' "$duration"
    printf 'boot_id=%s\n' "$boot_id"
    printf 'at_job_id=%s\n' "$at_id"
  } > "$tmp"
  chmod 600 -- "$tmp"
  mv -f -- "$tmp" "$STATE_FILE"
}

function write_managed_block() {
  local jobs="$1"
  local created="$2"
  local assignment="MAKEFLAGS=\"-j${jobs}\""
  local tmp awk_status source_file

  [[ ! -L "$CONFIG_FILE" ]] || \
    die "Refusing to replace a symlink: $CONFIG_FILE"
  if [[ -e "$CONFIG_FILE" && ! -f "$CONFIG_FILE" ]]; then
    die "Configuration path is not a regular file: $CONFIG_FILE"
  fi

  mkdir -p -- "$CONFIG_DIR"
  tmp=$(mktemp "$CONFIG_DIR/.makepkg.conf.XXXXXX")

  if [[ -f "$CONFIG_FILE" ]]; then
    chmod --reference="$CONFIG_FILE" "$tmp"
    source_file="$CONFIG_FILE"
  else
    chmod 600 -- "$tmp"
    source_file=/dev/null
  fi

  if awk \
    -v open="$OPEN_MARKER" \
    -v closing="$CLOSE_MARKER" \
    -v created="$created" \
    -v assignment="$assignment" '
      BEGIN { inside = 0; seen = 0; bad = 0 }
      $0 == open {
        if (inside || seen) { bad = 1; exit }
        inside = 1
        seen = 1
        print open
        print "# created-config=" created
        print assignment
        next
      }
      $0 == closing {
        if (!inside) { bad = 1; exit }
        inside = 0
        print closing
        next
      }
      inside { next }
      { print }
      END {
        if (bad || inside) exit 2
        if (!seen) {
          print open
          print "# created-config=" created
          print assignment
          print closing
        }
      }
    ' "$source_file" 2>/dev/null > "$tmp"; then
    :
  else
    awk_status=$?
    rm -f -- "$tmp"
    if [[ -f "$CONFIG_FILE" ]]; then
      die 'Found malformed or duplicate managed markers in makepkg.conf.'
    fi
    (( awk_status == 0 )) || die 'Could not write makepkg.conf.'
  fi

  chmod --reference="$CONFIG_FILE" "$tmp" 2>/dev/null || chmod 600 -- "$tmp"
  mv -f -- "$tmp" "$CONFIG_FILE"
}

function read_created_marker() {
  local value
  [[ -f "$CONFIG_FILE" ]] || return 1
  value=$(awk -v open="$OPEN_MARKER" -v closing="$CLOSE_MARKER" '
    $0 == open { inside=1; next }
    $0 == closing { inside=0; next }
    inside && /^# created-config=[01]$/ {
      sub(/^# created-config=/, "")
      print
      exit
    }
  ' "$CONFIG_FILE")
  [[ "$value" == 0 || "$value" == 1 ]] || return 1
  printf '%s\n' "$value"
}

function remove_managed_block() {
  local tmp awk_status created="$1"
  local had_block=0

  [[ -e "$CONFIG_FILE" ]] || return 0
  [[ ! -L "$CONFIG_FILE" ]] || die "Refusing to edit a symlink: $CONFIG_FILE"
  [[ -f "$CONFIG_FILE" ]] || die "Not a regular file: $CONFIG_FILE"

  if ! grep -Fqx -- "$OPEN_MARKER" "$CONFIG_FILE"; then
    return 0
  fi
  had_block=1
  tmp=$(mktemp "$CONFIG_DIR/.makepkg.conf.XXXXXX")
  chmod --reference="$CONFIG_FILE" "$tmp"

  if awk -v open="$OPEN_MARKER" -v closing="$CLOSE_MARKER" '
      BEGIN { inside=0; seen=0; bad=0 }
      $0 == open {
        if (inside || seen) { bad=1; exit }
        inside=1
        seen=1
        next
      }
      $0 == closing {
        if (!inside) { bad=1; exit }
        inside=0
        next
      }
      inside { next }
      { print }
      END { if (bad || inside) exit 2 }
    ' "$CONFIG_FILE" > "$tmp"; then
    :
  else
    awk_status=$?
    rm -f -- "$tmp"
    (( awk_status == 0 )) || die 'Managed makepkg.conf markers are malformed.'
  fi

  mv -f -- "$tmp" "$CONFIG_FILE"
  if [[ "$created" == 1 ]] && ! grep -q '[^[:space:]]' "$CONFIG_FILE"; then
    rm -f -- "$CONFIG_FILE"
  fi
  (( had_block )) && vlog 'Removed the managed MAKEFLAGS block.'
}

function systemd_unit_dir() {
  printf '%s/systemd/user\n' "$XDG_HOME"
}

function write_exec_wrapper() {
  local target="$1"
  local internal_mode="$2"
  local tmp
  tmp=$(mktemp "$STATE_DIR/wrapper.XXXXXX")
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export XDG_CONFIG_HOME=%s\n' "$(path_quote_bash "$XDG_HOME")"
    printf 'export MAKEPKG_FLAGS_CONFIG=%s\n' \
      "$(path_quote_bash "$CONFIG_FILE")"
    printf 'export MAKEPKG_FLAGS_STATE_DIR=%s\n' \
      "$(path_quote_bash "$STATE_DIR")"
    printf 'exec /usr/bin/bash %s --internal-expire %s\n' \
      "$(path_quote_bash "$MANAGER_COPY")" "$internal_mode"
  } > "$tmp"
  chmod 700 -- "$tmp"
  mv -f -- "$tmp" "$target"
}

function write_systemd_service() {
  local unit_dir="$1"
  local service_name="$2"
  local wrapper_path="$3"
  local description="$4"
  local tmp
  tmp=$(mktemp "$unit_dir/.${service_name}.XXXXXX")
  {
    printf '[Unit]\nDescription=%s\n\n' "$description"
    printf '[Service]\nType=oneshot\nExecStart=/usr/bin/bash %s\n' \
      "$(systemd_quote "$wrapper_path")"
  } > "$tmp"
  chmod 644 -- "$tmp"
  mv -f -- "$tmp" "$unit_dir/$service_name"
}

function install_reboot_cleanup() {
  local unit_dir="$1"
  local wants_dir="$unit_dir/default.target.wants"

  mkdir -p -- "$unit_dir" "$wants_dir" || return 1
  write_exec_wrapper \
    "$STATE_DIR/reboot-wrapper.sh" reboot || return 1
  write_systemd_service "$unit_dir" \
    "$UNIT_BASE-reboot.service" "$STATE_DIR/reboot-wrapper.sh" \
    'Revert temporary makepkg MAKEFLAGS at next boot' || return 1
  ln -sfn -- "../$UNIT_BASE-reboot.service" \
    "$wants_dir/$UNIT_BASE-reboot.service" || return 1
  systemctl --user daemon-reload
}

function install_systemd_timer() {
  local unit_dir="$1"
  local expiry="$2"
  local wrapper="$STATE_DIR/timer-wrapper.sh"
  local service="$UNIT_BASE-expire.service"
  local timer="$UNIT_BASE-expire.timer"
  local on_calendar tmp

  on_calendar=$(date -u -d "@$expiry" '+%Y-%m-%d %H:%M:%S UTC') || \
    return 1
  mkdir -p -- "$unit_dir" "$unit_dir/timers.target.wants" || return 1
  write_exec_wrapper "$wrapper" timer || return 1
  write_systemd_service "$unit_dir" "$service" "$wrapper" \
    'Revert timed makepkg MAKEFLAGS override' || return 1

  tmp=$(mktemp "$unit_dir/.${timer}.XXXXXX") || return 1
  {
    printf '[Unit]\nDescription=Expire temporary makepkg MAKEFLAGS override\n\n'
    printf '[Timer]\nOnCalendar=%s\nPersistent=true\n' "$on_calendar"
    printf 'AccuracySec=1s\nUnit=%s\n\n' "$service"
    printf '[Install]\nWantedBy=timers.target\n'
  } > "$tmp"
  chmod 644 -- "$tmp"
  mv -f -- "$tmp" "$unit_dir/$timer" || return 1
  ln -sfn -- "../$timer" "$unit_dir/timers.target.wants/$timer" || return 1
  systemctl --user daemon-reload || return 1
  systemctl --user restart "$timer" 2>/dev/null || \
    systemctl --user start "$timer"
}

function cancel_at_job() {
  local job_id="${1:-}"
  [[ "$job_id" =~ ^[0-9]+$ ]] || return 0
  command -v atrm >/dev/null 2>&1 || return 0
  atrm "$job_id" >/dev/null 2>&1 || true
}

function stop_and_remove_units() {
  local unit_dir="$1"
  local internal="${2:-0}"
  local timer="$UNIT_BASE-expire.timer"
  local expire_service="$UNIT_BASE-expire.service"
  local reboot_service="$UNIT_BASE-reboot.service"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user stop "$timer" >/dev/null 2>&1 || true
    if (( ! internal )); then
      systemctl --user stop "$expire_service" "$reboot_service" \
        >/dev/null 2>&1 || true
    fi
    systemctl --user disable "$timer" >/dev/null 2>&1 || true
  fi

  rm -f -- \
    "$unit_dir/timers.target.wants/$timer" \
    "$unit_dir/default.target.wants/$reboot_service" \
    "$unit_dir/$timer" \
    "$unit_dir/$expire_service" \
    "$unit_dir/$reboot_service"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
}

function schedule_at_job() {
  local expiry="$1"
  local wrapper="$2"
  local at_time output job_id
  at_time=$(date -d "@$expiry" '+%Y%m%d%H%M.%S') || \
    die 'Could not convert deadline for the at scheduler.'
  if ! output=$(at -t "$at_time" < "$wrapper" 2>&1); then
    printf '%s\n' "$output" >&2
    return 1
  fi
  job_id=$(sed -n 's/^job \([0-9][0-9]*\) at .*/\1/p' <<< "$output")
  if [[ ! "$job_id" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$output" >&2
    return 1
  fi
  printf '%s\n' "$job_id"
}

function install_at_timer() {
  local expiry="$1"
  local wrapper="$STATE_DIR/timer-wrapper.sh"
  write_exec_wrapper "$wrapper" timer || return 1
  schedule_at_job "$expiry" "$wrapper"
}

function current_boot_id() {
  [[ -r /proc/sys/kernel/random/boot_id ]] || return 1
  IFS= read -r REPLY < /proc/sys/kernel/random/boot_id
  [[ -n "$REPLY" ]]
}

function format_duration() {
  local seconds="$1"
  local days hours minutes remainder result=''

  days=$((seconds / 86400))
  remainder=$((seconds % 86400))
  hours=$((remainder / 3600))
  remainder=$((remainder % 3600))
  minutes=$((remainder / 60))
  seconds=$((remainder % 60))

  if (( days > 0 )); then result+="${days}d "; fi
  if (( hours > 0 )); then result+="${hours}h "; fi
  if (( minutes > 0 )); then result+="${minutes}m "; fi
  if (( seconds > 0 )); then result+="${seconds}s "; fi
  result=${result% }
  [[ -n "$result" ]] || result='0s'
  printf '%s\n' "$result"
}

function print_managed_block() {
  if [[ -f "$CONFIG_FILE" ]] && \
    grep -Fqx -- "$OPEN_MARKER" "$CONFIG_FILE"; then
    awk -v open="$OPEN_MARKER" -v closing="$CLOSE_MARKER" '
      $0 == open { inside=1 }
      inside { print }
      $0 == closing { exit }
    ' "$CONFIG_FILE"
  else
    printf '(managed block is missing from the configuration file)\n'
  fi
}

function cleanup_managed_state() {
  local internal="${1:-0}"
  local expected="${2:-}"
  local mode jobs created scheduler expiry boot_id at_id unit_dir
  mode=$(read_state_value mode || true)
  jobs=$(read_state_value jobs || true)
  created=$(read_state_value created_config || true)
  scheduler=$(read_state_value scheduler || true)
  expiry=$(read_state_value expires_at || true)
  boot_id=$(read_state_value boot_id || true)
  at_id=$(read_state_value at_job_id || true)
  unit_dir=$(systemd_unit_dir)

  if [[ -n "$expected" ]]; then
    [[ "$mode" == "$expected" ]] || {
      vlog "Ignoring stale $expected cleanup; current mode is ${mode:-unset}."
      return 0
    }
  fi

  if (( internal )) && [[ "$expected" == reboot && "$mode" == reboot && \
      -n "$boot_id" ]]; then
    local now_boot
    current_boot_id || die 'Cannot determine the current boot identifier.'
    now_boot="$REPLY"
    if [[ "$now_boot" == "$boot_id" ]]; then
      vlog 'Boot cleanup fired during the same boot; keeping the setting.'
      return 0
    fi
  fi

  if (( internal )) && [[ "$expected" == timer && "$mode" == timer && \
      "$expiry" =~ ^[0-9]+$ ]]; then
    if (( $(date +%s) < expiry )); then
      vlog 'Timer cleanup ran before its deadline; keeping the setting.'
      return 0
    fi
  fi

  if [[ -z "$mode" ]]; then
    if [[ ! -f "$CONFIG_FILE" ]] || \
      ! grep -Fqx -- "$OPEN_MARKER" "$CONFIG_FILE"; then
      if (( ! internal )); then
        log 'No managed override is active.'
      fi
      return 0
    fi
  fi

  (( internal )) || log 'Reverting the managed makepkg configuration.'
  [[ "$created" == 1 ]] || created=$(read_created_marker || printf '0')
  stop_and_remove_units "$unit_dir" "$internal"
  [[ "$scheduler" == at ]] && cancel_at_job "$at_id"
  remove_managed_block "$created"
  rm -f -- "$STATE_FILE" "$MANAGER_COPY" \
    "$STATE_DIR/reboot-wrapper.sh" "$STATE_DIR/timer-wrapper.sh"
  rmdir --ignore-fail-on-non-empty -- "$STATE_DIR" 2>/dev/null || true
  if (( ! internal )); then
    log 'Reverted. makepkg will use the remaining per-user/system configuration.'
  else
    vlog 'Expired override removed.'
  fi
}

function print_status() {
  local mode jobs created scheduler expiry duration at_id remaining now
  mode=$(read_state_value mode || true)
  jobs=$(read_state_value jobs || true)
  scheduler=$(read_state_value scheduler || true)
  expiry=$(read_state_value expires_at || true)
  duration=$(read_state_value duration_seconds || true)
  at_id=$(read_state_value at_job_id || true)

  printf 'Configuration file: %s\n' "$CONFIG_FILE"
  if [[ -z "$mode" ]]; then
    if [[ -f "$CONFIG_FILE" ]] && \
      grep -Fqx -- "$OPEN_MARKER" "$CONFIG_FILE"; then
      printf 'Managed state: marker exists, but its state file is missing.\n'
      printf 'Use --revert to remove the orphaned managed block.\n'
    else
      printf 'Managed state: no active override.\n'
      printf 'makepkg will use its remaining user/system configuration.\n'
    fi
    return 0
  fi

  printf 'Managed state: %s\n' "$mode"
  printf 'MAKEFLAGS: -j%s\n' "$jobs"
  printf 'Managed configuration block:\n'
  print_managed_block
  if [[ "$mode" == timer ]]; then
    now=$(date +%s)
    if [[ "$expiry" =~ ^[0-9]+$ ]]; then
      remaining=$((expiry - now))
      printf 'Expires: %s\n' "$(date -d "@$expiry" '+%Y-%m-%d %H:%M:%S %Z')"
      if [[ "$duration" =~ ^[0-9]+$ ]]; then
        printf 'Duration set: %s\n' "$(format_duration "$duration")"
      else
        printf 'Duration set: unknown\n'
      fi
      if (( remaining > 0 )); then
        printf 'Time remaining: %s\n' "$(format_duration "$remaining")"
      else
        printf 'Time remaining: expired; cleanup is pending.\n'
      fi
    fi
    printf 'Scheduler: %s\n' "${scheduler:-unknown}"
    [[ "$scheduler" != at ]] || printf 'at job ID: %s\n' "${at_id:-unknown}"
  elif [[ "$mode" == reboot ]]; then
    printf 'Cleanup: next user systemd-manager start after reboot.\n'
  else
    printf 'Cleanup: only by changing or reverting this setting.\n'
  fi
}

function parse_arguments() {
  local arg lower value consumed
  MODE_REQUEST=''
  EXPLICIT_MODE=0
  CORES_VALUE=''
  PRESET_VALUE=''
  TIMER_SECONDS=0
  TIMER_CONSUMED=0
  ACTION='set'
  local saw_cores=0 saw_preset=0 saw_timer=0 saw_persist=0
  local saw_revert=0 saw_status=0

  while (($#)); do
    arg="$1"
    lower="${arg,,}"
    case "$lower" in
      -h|--help)
        usage
        exit 0
        ;;
      --long-help)
        long_help
        exit 0
        ;;
      -v|--verbose)
        VERBOSE=1
        shift
        ;;
      --status)
        saw_status=1
        shift
        ;;
      --revert|--default)
        saw_revert=1
        shift
        ;;
      --persist)
        saw_persist=1
        shift
        ;;
      -c|--cores)
        (($# >= 2)) || die "$arg requires a value."
        (( ! saw_cores )) || die 'Specify --cores only once.'
        saw_cores=1
        CORES_VALUE=$(normalize_positive_integer 'Core count' "$2")
        shift 2
        ;;
      --cores=*)
        (( ! saw_cores )) || die 'Specify --cores only once.'
        saw_cores=1
        value="${arg#*=}"
        CORES_VALUE=$(normalize_positive_integer 'Core count' "$value")
        shift
        ;;
      -p|--preset)
        (($# >= 2)) || die "$arg requires low, medium, or high."
        (( ! saw_preset )) || die 'Specify --preset only once.'
        saw_preset=1
        PRESET_VALUE="${2,,}"
        case "$PRESET_VALUE" in
          low|medium|high) ;;
          *) die "Unknown preset '$2'; use low, medium, or high." ;;
        esac
        shift 2
        ;;
      --preset=*)
        (( ! saw_preset )) || die 'Specify --preset only once.'
        saw_preset=1
        PRESET_VALUE="${arg#*=}"
        PRESET_VALUE="${PRESET_VALUE,,}"
        case "$PRESET_VALUE" in
          low|medium|high) ;;
          *) die "Unknown preset '${arg#*=}'; use low, medium, or high." ;;
        esac
        shift
        ;;
      -t|--timer)
        (( ! saw_timer )) || die 'Specify --timer only once.'
        saw_timer=1
        shift
        parse_timer_args "$@"
        consumed=$TIMER_CONSUMED
        shift "$consumed"
        ;;
      --timer=*)
        (( ! saw_timer )) || die 'Specify --timer only once.'
        saw_timer=1
        value="${arg#*=}"
        TIMER_SECONDS=0
        parse_compact_duration "${value,,}"
        (( TIMER_SECONDS > 0 )) || \
          die 'Timer duration must be greater than zero.'
        shift
        ;;
      *)
        die "Unknown option or argument: $arg"
        ;;
    esac
  done

  (( saw_cores + saw_preset <= 1 )) || \
    die '--cores and --preset are mutually exclusive.'
  (( saw_timer + saw_persist <= 1 )) || \
    die '--timer and --persist are mutually exclusive.'
  if (( saw_revert )); then
    (( ! saw_status && ! saw_cores && ! saw_preset && ! saw_timer && \
      ! saw_persist )) || \
      die '--revert/--default cannot be combined with other actions.'
    ACTION='revert'
    return
  fi
  if (( saw_status )); then
    (( ! saw_cores && ! saw_preset && ! saw_timer && ! saw_persist )) || \
      die '--status cannot be combined with setting changes.'
    ACTION='status'
    return
  fi

  if (( saw_timer )); then
    MODE_REQUEST='timer'
    EXPLICIT_MODE=1
  elif (( saw_persist )); then
    MODE_REQUEST='persistent'
    EXPLICIT_MODE=1
  else
    MODE_REQUEST='reboot'
  fi

  if (( saw_cores + saw_preset + saw_timer + saw_persist == 0 )); then
    usage
    exit 0
  fi
}

function resolve_jobs() {
  local requested="$1"
  local available jobs

  if [[ -n "$CORES_VALUE" ]]; then
    printf '%s\n' "$CORES_VALUE"
    return
  fi
  if [[ -n "$PRESET_VALUE" ]]; then
    available=$(nproc 2>/dev/null || \
      getconf _NPROCESSORS_ONLN 2>/dev/null || true)
    available=$(normalize_positive_integer \
      'Available processor count' "$available")
    case "$PRESET_VALUE" in
      low) jobs=$((available / 4)) ;;
      medium) jobs=$((available / 2)) ;;
      high) jobs="$available" ;;
    esac
    (( jobs > 0 )) || jobs=1
    vlog "Detected $available processors; '$PRESET_VALUE' gives $jobs jobs."
    printf '%s\n' "$jobs"
    return
  fi

  if [[ -n "$requested" ]]; then
    printf '%s\n' "$requested"
    return
  fi

  die 'No core count was provided and no managed setting can be promoted.'
}

function choose_temporary_scheduler() {
  local explicit_timer="$1"
  if detect_systemd_user; then
    SCHEDULER='systemd'
    return
  fi
  if detect_at_scheduler; then
    SCHEDULER='at'
    if [[ "$explicit_timer" == 0 ]]; then
      TIMER_SECONDS=$DEFAULT_FALLBACK_SECONDS
      log 'systemd --user is unavailable; using an eight-hour atd fallback.'
    else
      log 'systemd --user is unavailable; using the active atd scheduler.'
    fi
    return
  fi

  die 'No usable temporary scheduler: systemd --user is unavailable and' \
    'no active atd service was found. No configuration was changed.'
}

function apply_setting() {
  local selected_mode="$MODE_REQUEST"
  local prior_jobs prior_created prior_mode prior_scheduler prior_at_id
  local jobs created expiry='' duration='' scheduler='' boot_id='' at_id=''
  local unit_dir manager_source

  prior_mode=$(read_state_value mode || true)
  prior_jobs=$(read_state_value jobs || true)
  prior_created=$(read_state_value created_config || true)
  prior_scheduler=$(read_state_value scheduler || true)
  prior_at_id=$(read_state_value at_job_id || true)
  if [[ -z "$prior_created" ]]; then
    prior_created=$(read_created_marker || true)
  fi

  if [[ "$selected_mode" == persistent && -z "$CORES_VALUE$PRESET_VALUE" ]]; then
    [[ -n "$prior_jobs" ]] || \
      die '--persist without --cores/--preset needs an active managed setting.'
  fi
  if [[ "$selected_mode" == timer && "$TIMER_SECONDS" -eq 0 ]]; then
    [[ -n "$prior_jobs" ]] || \
      die '--timer without --cores/--preset needs an active managed setting.'
  fi

  jobs=$(resolve_jobs "$prior_jobs")
  if [[ "$prior_created" == 0 || "$prior_created" == 1 ]]; then
    created="$prior_created"
  elif [[ -e "$CONFIG_FILE" ]]; then
    created=0
  else
    created=1
  fi

  if [[ "$selected_mode" == timer || "$selected_mode" == reboot ]]; then
    local explicit_timer=0
    if [[ "$selected_mode" == timer && "$TIMER_SECONDS" -gt 0 ]]; then
      explicit_timer=1
    fi
    choose_temporary_scheduler "$explicit_timer"
    scheduler="$SCHEDULER"
    if [[ "$selected_mode" == reboot && "$scheduler" == at ]]; then
      selected_mode=timer
      duration=$TIMER_SECONDS
    elif [[ "$selected_mode" == timer ]]; then
      duration=$TIMER_SECONDS
    fi
    if [[ "$selected_mode" == timer ]]; then
      expiry=$(( $(date +%s) + TIMER_SECONDS ))
      (( expiry > 0 )) || die 'Timer deadline is outside the supported range.'
    fi
  fi

  if [[ "$selected_mode" == reboot ]]; then
    current_boot_id || die 'Cannot determine the current boot identifier.'
    boot_id="$REPLY"
  fi

  mkdir -p -- "$STATE_DIR"
  chmod 700 -- "$STATE_DIR"
  manager_source=$(readlink -f -- "$0") || die 'Cannot resolve the script path.'
  [[ -f "$manager_source" ]] || die 'The script must be run from a regular file.'
  MANAGER_COPY="$STATE_DIR/manager.sh"
  cp -- "$manager_source" "$MANAGER_COPY"
  chmod 700 -- "$MANAGER_COPY"

  write_managed_block "$jobs" "$created"
  write_state "$selected_mode" "$jobs" "$created" "$scheduler" \
    "$expiry" "$duration" "$boot_id" ''

  unit_dir=$(systemd_unit_dir)
  stop_and_remove_units "$unit_dir" 0
  if [[ "$prior_mode" == timer && "$prior_scheduler" == at ]]; then
    cancel_at_job "$prior_at_id"
  fi

  case "$selected_mode" in
    persistent)
      rm -f -- "$MANAGER_COPY" "$STATE_DIR/reboot-wrapper.sh" \
        "$STATE_DIR/timer-wrapper.sh"
      log "Set MAKEFLAGS=\"-j$jobs\" persistently."
      ;;
    reboot)
      install_reboot_cleanup "$unit_dir" || {
        cleanup_managed_state 0 ''
        die 'Could not install reboot cleanup; the managed override was' \
          'reverted.'
      }
      log "Set MAKEFLAGS=\"-j$jobs\" until the next reboot."
      log 'Cleanup runs when your user systemd manager starts after reboot.'
      ;;
    timer)
      if [[ "$scheduler" == systemd ]]; then
        install_systemd_timer "$unit_dir" "$expiry" || {
          cleanup_managed_state 0 ''
          die 'Could not install the timer; the managed override was reverted.'
        }
      else
        at_id=$(install_at_timer "$expiry") || {
          cleanup_managed_state 0 ''
          die 'Could not install the atd timer; the managed override was' \
            'reverted.'
        }
        write_state "$selected_mode" "$jobs" "$created" "$scheduler" \
          "$expiry" "$duration" '' "$at_id"
      fi
      log "Set MAKEFLAGS=\"-j$jobs\" with a timed revert."
      log "Deadline: $(date -d "@$expiry" '+%Y-%m-%d %H:%M:%S %Z')"
      ;;
    *)
      die "Internal error: unexpected mode '$selected_mode'."
      ;;
  esac

  if [[ "$scheduler" == at && "$selected_mode" == timer ]]; then
    vlog "Scheduled at job $at_id."
  fi
  vlog "Configuration: $CONFIG_FILE"
  log 'Run --status to inspect the active setting or --revert to remove it now.'
}

function main() {
  parse_arguments "$@"
  [[ "${EUID:-$(id -u)}" -ne 0 ]] || \
    die 'Run this as the target user, without sudo.'

  XDG_HOME=$(xdg_config_home)
  CONFIG_DIR="$XDG_HOME/pacman"
  CONFIG_FILE="${MAKEPKG_FLAGS_CONFIG:-$CONFIG_DIR/makepkg.conf}"
  STATE_DIR="${MAKEPKG_FLAGS_STATE_DIR:-$CONFIG_DIR/.makepkg-flags-manager}"
  STATE_FILE="$STATE_DIR/state"
  MANAGER_COPY="$STATE_DIR/manager.sh"
  [[ "$CONFIG_FILE" == /* && "$STATE_DIR" == /* ]] || \
    die 'Resolved configuration and state paths must be absolute.'
  [[ "$CONFIG_FILE" != *$'\n'* && "$STATE_DIR" != *$'\n'* ]] || \
    die 'Configuration and state paths may not contain newlines.'

  case "$ACTION" in
    status)
      print_status
      ;;
    revert)
      cleanup_managed_state 0 ''
      ;;
    set)
      apply_setting
      ;;
  esac
}

if [[ "${1:-}" == --internal-expire ]]; then
  [[ $# -eq 2 ]] || exit 2
  XDG_HOME=$(xdg_config_home)
  CONFIG_DIR="$XDG_HOME/pacman"
  CONFIG_FILE="${MAKEPKG_FLAGS_CONFIG:-$CONFIG_DIR/makepkg.conf}"
  STATE_DIR="${MAKEPKG_FLAGS_STATE_DIR:-$CONFIG_DIR/.makepkg-flags-manager}"
  STATE_FILE="$STATE_DIR/state"
  MANAGER_COPY="$STATE_DIR/manager.sh"
  case "$2" in
    reboot|timer) cleanup_managed_state 1 "$2" ;;
    *) exit 2 ;;
  esac
else
  main "$@"
fi
